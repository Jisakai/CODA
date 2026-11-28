import Foundation
import Observation
import CodaMusic

/// Metadata summary displayed in the Procreate-style Project Gallery / Save Hub.
public struct ProjectSummary: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var tempo: Double
    public var keyDisplayName: String
    public var barCount: Int
    public var chordCount: Int
    public var previewChordNames: [String]

    public init(
        id: String,
        name: String,
        createdAt: Date,
        modifiedAt: Date,
        tempo: Double,
        keyDisplayName: String,
        barCount: Int,
        chordCount: Int,
        previewChordNames: [String]
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.tempo = tempo
        self.keyDisplayName = keyDisplayName
        self.barCount = barCount
        self.chordCount = chordCount
        self.previewChordNames = previewChordNames
    }
}

public enum ProjectHubError: Error, LocalizedError, Sendable {
    case invalidName
    case projectNotFound(String)
    case corruptProject(String)
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Project name cannot be empty."
        case .projectNotFound: return "Project file could not be found."
        case .corruptProject(let reason): return "Invalid project file: \(reason)"
        case .ioFailure(let reason): return "File operation failed: \(reason)"
        }
    }
}

/// Manages local project files, atomic saves, crash-safe autosave/recovery, and import/export (SPEC §19, Nov 28 Save Hub).
@MainActor
@Observable
public final class ProjectHubStore {
    public private(set) var projects: [ProjectSummary] = []
    public private(set) var activeProjectID: String?
    public private(set) var lastSavedAt: Date?
    public private(set) var hasUnsavedChanges: Bool = false
    public private(set) var lastError: String?

    private let directory: URL
    private let autosaveURL: URL
    private var vocabulary: ChordVocabulary?

    private static let pitchNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    public init(directory: URL? = nil, vocabulary: ChordVocabulary? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.directory = appSupport
                .appendingPathComponent("coda", isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
        }
        self.autosaveURL = self.directory.appendingPathComponent(".autosave-recovery.coda.json")
        self.vocabulary = vocabulary

        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        refreshIndex()
    }

    public func refreshIndex() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            projects = []
            return
        }
        var loaded: [ProjectSummary] = []
        for url in urls where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let doc = try? CodaProjectDocument.decodeJSON(data) {
                loaded.append(summary(for: doc))
            }
        }
        projects = loaded.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func markDirty() {
        hasUnsavedChanges = true
    }

    @discardableResult
    public func save(_ document: CodaProjectDocument) throws -> ProjectSummary {
        var updated = document
        updated.modifiedAt = Date()
        let url = fileURL(for: updated.id)
        try writeAtomically(updated, to: url)
        activeProjectID = updated.id
        lastSavedAt = updated.modifiedAt
        hasUnsavedChanges = false
        lastError = nil
        clearAutosave()
        refreshIndex()
        return summary(for: updated)
    }

    public func writeAutosave(_ document: CodaProjectDocument) {
        try? writeAtomically(document, to: autosaveURL)
    }

    public func loadAutosaveRecovery() -> CodaProjectDocument? {
        guard FileManager.default.fileExists(atPath: autosaveURL.path),
              let data = try? Data(contentsOf: autosaveURL),
              let doc = try? CodaProjectDocument.decodeJSON(data)
        else { return nil }
        return doc
    }

    public func clearAutosave() {
        try? FileManager.default.removeItem(at: autosaveURL)
    }

    public func load(id: String) throws -> CodaProjectDocument {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectHubError.projectNotFound(id)
        }
        let data = try Data(contentsOf: url)
        do {
            let doc = try CodaProjectDocument.decodeJSON(data)
            activeProjectID = doc.id
            lastSavedAt = doc.modifiedAt
            hasUnsavedChanges = false
            lastError = nil
            return doc
        } catch {
            throw ProjectHubError.corruptProject(error.localizedDescription)
        }
    }

    @discardableResult
    public func createNew(name: String, vocabulary: ChordVocabulary) throws -> CodaProjectDocument {
        if self.vocabulary == nil { self.vocabulary = vocabulary }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? nextUntitledName() : trimmed
        let doc = CodaProjectDocument(name: finalName)
        _ = try save(doc)
        return doc
    }

    public func rename(id: String, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectHubError.invalidName }
        var doc = try load(id: id)
        doc.name = trimmed
        _ = try save(doc)
    }

    @discardableResult
    public func duplicate(id: String) throws -> CodaProjectDocument {
        let original = try load(id: id)
        let now = Date()
        var copy = original
        copy.id = UUID().uuidString
        copy.name = "\(original.name) Copy"
        copy.createdAt = now
        copy.modifiedAt = now
        _ = try save(copy)
        return copy
    }

    public func delete(id: String) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        if activeProjectID == id {
            activeProjectID = nil
        }
        refreshIndex()
    }

    public func exportJSONData(for document: CodaProjectDocument) throws -> Data {
        try document.encodeJSON(prettyPrinted: true)
    }

    public func importJSONData(_ data: Data) throws -> CodaProjectDocument {
        let decoded: CodaProjectDocument
        do {
            decoded = try CodaProjectDocument.decodeJSON(data)
        } catch {
            throw ProjectHubError.corruptProject(error.localizedDescription)
        }
        var imported = decoded
        if projects.contains(where: { $0.id == imported.id }) {
            imported.id = UUID().uuidString
            imported.name = "\(imported.name) (Imported)"
        }
        _ = try save(imported)
        return imported
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).coda.json")
    }

    private func writeAtomically(_ document: CodaProjectDocument, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try document.encodeJSON(prettyPrinted: true)
        let tmpURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tmpURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: url)
        }
    }

    private func summary(for doc: CodaProjectDocument) -> ProjectSummary {
        let bars = max(MusicDefaults.canvasBars, doc.arrangementTotalSteps / MusicDefaults.stepsPerBar)
        let names = doc.chordRegions.prefix(6).map { Self.formatChord($0.chord, vocabulary: vocabulary) }
        return ProjectSummary(
            id: doc.id,
            name: doc.name,
            createdAt: doc.createdAt,
            modifiedAt: doc.modifiedAt,
            tempo: doc.tempo,
            keyDisplayName: Self.formatKey(doc.key),
            barCount: bars,
            chordCount: doc.chordRegions.count,
            previewChordNames: names
        )
    }

    private static func formatKey(_ key: MusicalKey) -> String {
        let root = pitchNames[(key.tonic % 12 + 12) % 12]
        return "\(root) \(key.mode == .major ? "Maj" : "Min")"
    }

    private static func formatChord(_ chord: Chord, vocabulary: ChordVocabulary?) -> String {
        let root = pitchNames[(chord.root % 12 + 12) % 12]
        let symbol: String
        if let quality = try? vocabulary?.quality(chord.qualityID) {
            symbol = quality.symbol
        } else {
            symbol = fallbackSymbol(for: chord.qualityID)
        }
        let slash = chord.slashBass.map { "/\(pitchNames[($0 % 12 + 12) % 12])" } ?? ""
        return "\(root)\(symbol)\(slash)"
    }

    private static func fallbackSymbol(for qualityID: String) -> String {
        switch qualityID {
        case "major": return ""
        case "minor": return "m"
        case "major7": return "maj7"
        case "minor7": return "m7"
        case "dominant7": return "7"
        case "major9": return "maj9"
        case "minor9": return "m9"
        case "dominant9": return "9"
        case "sus2": return "sus2"
        case "sus4": return "sus4"
        case "add9": return "add9"
        case "diminished": return "dim"
        case "diminished7": return "dim7"
        case "halfDiminished": return "m7♭5"
        case "augmented": return "aug"
        case "power": return "5"
        default: return qualityID
        }
    }

    private func nextUntitledName() -> String {
        let base = "Untitled Sketch"
        if !projects.contains(where: { $0.name == base }) { return base }
        var index = 2
        while projects.contains(where: { $0.name == "\(base) \(index)" }) {
            index += 1
        }
        return "\(base) \(index)"
    }
}
