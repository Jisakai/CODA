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

public actor SidekickModelManager {
    public private(set) var state: SidekickModelState = .notDownloaded
    private let cacheDirectory: URL
    private var lastUsedAt: Date = .distantPast
    private var idleTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Error>?

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
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard hasSufficientMemory() else {
            let msg = "Not enough free memory to load Qwen3 4B right now. Music editing continues unaffected."
            state = .memoryConstrained(msg)
            throw SidekickRuntimeError.memoryConstrained(msg)
        }

        #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
        if container != nil {
            state = .loaded
            scheduleIdleUnload()
            return
        }
        state = .downloading(progress: 0.0)
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let loaded = try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: LLMRegistry.qwen3_4b_4bit
            ) { progress in
                let fraction = min(max(progress.fractionCompleted, 0.0), 1.0)
                onProgress(fraction)
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
            let msg = "Qwen3 4B model unavailable offline or failed to download: \(error.localizedDescription)"
            state = .offlineUnavailable(msg)
            throw SidekickRuntimeError.unavailable(msg)
        }
        #else
        let msg = "On-device MLX runtime not linked in this build. Qwen3 4B (\(SidekickModelConfig.repoID)) requires MLXLLM on iPadOS."
        state = .offlineUnavailable(msg)
        throw SidekickRuntimeError.unavailable(msg)
        #endif
    }

    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
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
        temperature: Float = 0.65
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.ensureModelReady { _ in }
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
                        "Qwen3 4B (\(SidekickModelConfig.repoID)) is unavailable in this build. Music editing and chord predictions continue normally."
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
