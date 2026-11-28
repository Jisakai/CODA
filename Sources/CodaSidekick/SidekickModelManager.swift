import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
#endif

/// Live byte- and phase-level progress for Qwen3 4B model provisioning.
public struct SidekickDownloadProgress: Equatable, Sendable {
    public let fraction: Double
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let statusText: String

    public init(
        fraction: Double,
        completedBytes: Int64,
        totalBytes: Int64,
        statusText: String
    ) {
        self.fraction = min(max(fraction, 0.0), 1.0)
        self.completedBytes = max(0, completedBytes)
        self.totalBytes = max(0, totalBytes)
        self.statusText = statusText
    }

    public var percentInt: Int {
        Int((fraction * 100.0).rounded())
    }

    public var formattedBytes: String {
        let total = totalBytes > 0 ? totalBytes : SidekickModelConfig.estimatedDownloadBytes
        let completed = completedBytes > 0
            ? completedBytes
            : Int64(Double(total) * fraction)
        if completed <= 0 && fraction <= 0 {
            return "0 MB / \(Self.formatByteCount(total))"
        }
        return "\(Self.formatByteCount(completed)) / \(Self.formatByteCount(total))"
    }

    private static func formatByteCount(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000.0
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        }
        let mb = Double(bytes) / 1_000_000.0
        return String(format: "%.0f MB", max(0, mb))
    }
}

/// Provisioning, memory safety, and streaming inference backend for Qwen3 4B 4-bit (SPEC §14.3, §20).
public enum SidekickModelState: Equatable, Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case ready
    case loaded
    case unloadedIdle
    case offlineUnavailable(String)
    case memoryConstrained(String)
}

public struct SidekickModelConfig: Sendable {
    public static let repoID = "mlx-community/Qwen3-4B-Instruct-2507-gabliterated-4bit"
    public static let estimatedDownloadBytes: Int64 = 2_280_000_000 // ~2.28 GB verified HF size
    public static let minimumAvailableMemoryBytes: UInt64 = 3_200_000_000 // Conservative headroom check
    public static let idleUnloadSeconds: TimeInterval = 300 // Unload weights after 5 min idle
}

private struct HuggingFaceModelInfo: Decodable, Sendable {
    struct Sibling: Decodable, Sendable {
        let rfilename: String
        let size: Int64?
        let lfs: LFSInfo?
    }
    struct LFSInfo: Decodable, Sendable {
        let size: Int64?
    }
    let siblings: [Sibling]
}

/// Native URLSession download delegate with NSLock-guarded state for Swift 6 concurrency safety.
private final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private let destinationURL: URL
    private let onBytesWritten: @Sendable (Int64, Int64) -> Void
    private var lastReportedTime: TimeInterval = 0

    init(
        destinationURL: URL,
        onBytesWritten: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        self.destinationURL = destinationURL
        self.onBytesWritten = onBytesWritten
    }

    func attach(continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    private func finish(with result: Result<URL, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let shouldReport = (now - lastReportedTime) >= 0.12
            || (totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite)
        if shouldReport { lastReportedTime = now }
        lock.unlock()
        if shouldReport {
            onBytesWritten(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            finish(with: .failure(SidekickRuntimeError.unavailable("Hugging Face returned HTTP \(http.statusCode) for \(destinationURL.lastPathComponent).")))
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.moveItem(at: location, to: destinationURL)
            finish(with: .success(destinationURL))
        } catch {
            finish(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled {
            finish(with: .failure(CancellationError()))
        } else {
            finish(with: .failure(error))
        }
    }
}

public actor SidekickModelManager {
    public private(set) var state: SidekickModelState = .notDownloaded
    private let cacheDirectory: URL
    private var lastUsedAt: Date = .distantPast
    private var idleTask: Task<Void, Never>?
    private var activeDownloadTask: Task<Void, Error>?
    private var activeURLTask: URLSessionDownloadTask?

    #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
    private var container: ModelContainer?
    #endif

    public init(cacheDirectory: URL? = nil) {
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.cacheDirectory = appSupport
                .appendingPathComponent("coda", isDirectory: true)
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("qwen3-4b-4bit", isDirectory: true)
        }
        self.state = Self.detectInitialState(at: self.cacheDirectory)
    }

    public static var isMLXRuntimeAvailable: Bool {
        #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
        return true
        #else
        return false
        #endif
    }

    private static func detectInitialState(at directory: URL) -> SidekickModelState {
        let marker = directory.appendingPathComponent(".ready")
        if FileManager.default.fileExists(atPath: marker.path) {
            return .ready
        }
        return .notDownloaded
    }

    /// Check runtime available process memory before loading 4B quantized weights (SPEC §20 item 4).
    public func hasSufficientMemory() -> Bool {
        #if os(iOS)
        let available = UInt64(os_proc_available_memory())
        // Simulator often reports 0; allow when unavailable to query
        if available == 0 { return true }
        return available >= SidekickModelConfig.minimumAvailableMemoryBytes
        #else
        return true
        #endif
    }

    public func ensureModelReady(
        onProgress: @escaping @Sendable (SidekickDownloadProgress) -> Void
    ) async throws {
        guard hasSufficientMemory() else {
            let msg = "Not enough free memory to load Qwen3 4B right now. Music editing continues unaffected."
            state = .memoryConstrained(msg)
            throw SidekickRuntimeError.memoryConstrained(msg)
        }

        if let existing = activeDownloadTask {
            try await existing.value
            return
        }

        let task = Task<Void, Error> { [self] in
            try await self.performProvision(onProgress: onProgress)
        }
        activeDownloadTask = task
        defer {
            activeDownloadTask = nil
            activeURLTask = nil
        }
        try await task.value
    }

    private func performProvision(
        onProgress: @escaping @Sendable (SidekickDownloadProgress) -> Void
    ) async throws {
        #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
        if container != nil {
            state = .loaded
            scheduleIdleUnload()
            return
        }
        state = .downloading(progress: 0.0)
        onProgress(SidekickDownloadProgress(
            fraction: 0.0,
            completedBytes: 0,
            totalBytes: SidekickModelConfig.estimatedDownloadBytes,
            statusText: "Connecting to Hugging Face…"
        ))
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let config = ModelConfiguration(id: SidekickModelConfig.repoID)
            let loaded = try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: config
            ) { progress in
                let fraction = min(max(progress.fractionCompleted, 0.0), 1.0)
                let total = progress.totalUnitCount > 1_000_000
                    ? progress.totalUnitCount
                    : SidekickModelConfig.estimatedDownloadBytes
                let completed = progress.totalUnitCount > 1_000_000
                    ? progress.completedUnitCount
                    : Int64(Double(total) * fraction)
                let phase = fraction >= 0.99
                    ? "Loading Qwen3-4B into GPU memory…"
                    : "Downloading \(SidekickModelConfig.repoID)…"
                onProgress(SidekickDownloadProgress(
                    fraction: fraction,
                    completedBytes: completed,
                    totalBytes: total,
                    statusText: phase
                ))
            }
            self.container = loaded
            let marker = cacheDirectory.appendingPathComponent(".ready")
            try? Data("ready".utf8).write(to: marker, options: .atomic)
            state = .loaded
            scheduleIdleUnload()
        } catch is CancellationError {
            state = Self.detectInitialState(at: cacheDirectory)
            throw CancellationError()
        } catch {
            let msg = "Qwen3 4B download failed: \(error.localizedDescription)"
            state = .offlineUnavailable(msg)
            throw SidekickRuntimeError.unavailable(msg)
        }
        #else
        if Self.detectInitialState(at: cacheDirectory) == .ready {
            state = .ready
            return
        }
        state = .downloading(progress: 0.0)
        onProgress(SidekickDownloadProgress(
            fraction: 0.0,
            completedBytes: 0,
            totalBytes: SidekickModelConfig.estimatedDownloadBytes,
            statusText: "Connecting to Hugging Face…"
        ))
        do {
            try await downloadModelFromHuggingFace(onProgress: onProgress)
            let marker = cacheDirectory.appendingPathComponent(".ready")
            try Data(SidekickModelConfig.repoID.utf8).write(to: marker, options: .atomic)
            state = .ready
        } catch is CancellationError {
            state = Self.detectInitialState(at: cacheDirectory)
            throw CancellationError()
        } catch {
            let msg = "Qwen3 4B download failed: \(error.localizedDescription)"
            state = .offlineUnavailable(msg)
            throw SidekickRuntimeError.unavailable(msg)
        }
        #endif
    }

    private func downloadModelFromHuggingFace(
        onProgress: @escaping @Sendable (SidekickDownloadProgress) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        guard let apiURL = URL(string: "https://huggingface.co/api/models/\(SidekickModelConfig.repoID)?blobs=true") else {
            throw SidekickRuntimeError.unavailable("Invalid Hugging Face repository URL.")
        }

        let (data, response) = try await URLSession.shared.data(from: apiURL)
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SidekickRuntimeError.unavailable("Hugging Face API returned HTTP \(http.statusCode).")
        }

        let info = try JSONDecoder().decode(HuggingFaceModelInfo.self, from: data)
        let files = info.siblings.filter { sibling in
            let name = sibling.rfilename.lowercased()
            return name.hasSuffix(".safetensors")
                || name.hasSuffix(".json")
                || name == "merges.txt"
                || name == "tokenizer.model"
        }
        guard !files.isEmpty else {
            throw SidekickRuntimeError.unavailable("No downloadable model files found in \(SidekickModelConfig.repoID).")
        }

        let declaredTotal = files.reduce(Int64(0)) { partial, sibling in
            partial + (sibling.lfs?.size ?? sibling.size ?? 0)
        }
        let totalBytes = declaredTotal > 0 ? declaredTotal : SidekickModelConfig.estimatedDownloadBytes
        var completedBeforeFile: Int64 = 0

        for file in files {
            try Task.checkCancellation()
            let fileSize = file.lfs?.size ?? file.size ?? 0
            let dest = cacheDirectory.appendingPathComponent(file.rfilename)

            // Resume-friendly: skip files already cached with matching size.
            if FileManager.default.fileExists(atPath: dest.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
               let existingSize = (attrs[.size] as? NSNumber)?.int64Value,
               fileSize > 0 && existingSize == fileSize {
                completedBeforeFile += existingSize
                let frac = min(Double(completedBeforeFile) / Double(max(1, totalBytes)), 1.0)
                state = .downloading(progress: frac)
                onProgress(SidekickDownloadProgress(
                    fraction: frac,
                    completedBytes: completedBeforeFile,
                    totalBytes: totalBytes,
                    statusText: "Verified \(file.rfilename)"
                ))
                continue
            }

            let encodedName = file.rfilename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.rfilename
            guard let fileURL = URL(string: "https://huggingface.co/\(SidekickModelConfig.repoID)/resolve/main/\(encodedName)") else {
                continue
            }

            let baseCompleted = completedBeforeFile
            let fileLabel = URL(fileURLWithPath: file.rfilename).lastPathComponent
            onProgress(SidekickDownloadProgress(
                fraction: min(Double(baseCompleted) / Double(max(1, totalBytes)), 1.0),
                completedBytes: baseCompleted,
                totalBytes: totalBytes,
                statusText: "Downloading \(fileLabel)…"
            ))

            try await downloadSingleFile(
                from: fileURL,
                to: dest
            ) { written, _ in
                let overall = min(baseCompleted + written, totalBytes)
                let frac = min(Double(overall) / Double(max(1, totalBytes)), 0.995)
                onProgress(SidekickDownloadProgress(
                    fraction: frac,
                    completedBytes: overall,
                    totalBytes: totalBytes,
                    statusText: "Downloading \(fileLabel)…"
                ))
            }

            if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
               let actualSize = (attrs[.size] as? NSNumber)?.int64Value {
                completedBeforeFile += actualSize
            } else {
                completedBeforeFile += fileSize
            }
            let frac = min(Double(completedBeforeFile) / Double(max(1, totalBytes)), 1.0)
            state = .downloading(progress: frac)
            onProgress(SidekickDownloadProgress(
                fraction: frac,
                completedBytes: completedBeforeFile,
                totalBytes: totalBytes,
                statusText: frac >= 0.999 ? "Finalizing model cache…" : "Downloaded \(fileLabel)"
            ))
        }
    }

    private func downloadSingleFile(
        from url: URL,
        to destination: URL,
        onBytesWritten: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let delegate = FileDownloadDelegate(destinationURL: destination, onBytesWritten: onBytesWritten)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let downloadTask = session.downloadTask(with: url)
        activeURLTask = downloadTask
        defer {
            activeURLTask = nil
            session.finishTasksAndInvalidate()
        }

        try await withTaskCancellationHandler {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                delegate.attach(continuation: continuation)
                downloadTask.resume()
            }
        } onCancel: {
            downloadTask.cancel()
        }
    }

    public func cancelDownload() {
        activeURLTask?.cancel()
        activeURLTask = nil
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        if case .downloading = state {
            state = Self.detectInitialState(at: cacheDirectory)
        }
    }

    /// Unload active LLM weights when idle to protect iPadOS memory limits (SPEC §20 item 4).
    public func unloadWeights() {
        #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
        container = nil
        #endif
        idleTask?.cancel()
        idleTask = nil
        if case .loaded = state {
            state = .unloadedIdle
        }
    }

    /// Stream tokens off the main and audio threads.
    public func streamCompletion(
        systemInstructions: String,
        userMessage: String,
        maxTokens: Int = 384,
        temperature: Float = 0.65,
        onDownloadProgress: (@Sendable (SidekickDownloadProgress) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.ensureModelReady { progress in
                        onDownloadProgress?(progress)
                    }
                    #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
                    guard let container = self.container else {
                        throw SidekickRuntimeError.unavailable("Qwen3 4B container is not loaded.")
                    }
                    let chat = ChatSession(
                        container,
                        instructions: systemInstructions,
                        generateParameters: GenerateParameters(
                            maxTokens: maxTokens,
                            temperature: temperature
                        )
                    )
                    for try await chunk in chat.streamResponse(to: userMessage) {
                        if Task.isCancelled { break }
                        continuation.yield(chunk)
                    }
                    self.touchUsage()
                    continuation.finish()
                    #else
                    throw SidekickRuntimeError.unavailable(
                        "Qwen3 4B weights are cached on device (\(SidekickModelConfig.repoID)), but MLXLLM inference runtime is not linked in this build yet."
                    )
                    #endif
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func touchUsage() {
        lastUsedAt = Date()
        scheduleIdleUnload()
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        let timeout = SidekickModelConfig.idleUnloadSeconds
        idleTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled {
                self.unloadWeights()
            }
        }
    }
}

public enum SidekickRuntimeError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case memoryConstrained(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .memoryConstrained(let message):
            return message
        }
    }
}
