import Foundation

/// Chord-strip only: no cross-layer clipboard or input-device policy.
public struct ChordClipboard: Equatable, Sendable {
    public let chord: Chord
    public let length: Int
    public let pitches: [Int]
    public init(region: ChordRegion) {
        chord = region.chord
        length = region.length
        pitches = region.pitches
    }
}

public enum ProgressionEdit: Sendable {
    case add(ChordRegion)
    case resize(id: String, start: Int, length: Int)
    case swap(id: String, chord: Chord)
    case duplicate(id: String, newID: String, start: Int)
    case paste(ChordClipboard, newID: String, start: Int)
    case delete(id: String)
}

public struct ProgressionEditor: Sendable {
    public private(set) var progression: Progression
    private var undoStack: [Progression] = []
    private var redoStack: [Progression] = []
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public init(_ progression: Progression) { self.progression = progression }

    public func copy(id: String) throws -> ChordClipboard {
        ChordClipboard(region: try region(id))
    }

    /// Audition is a read, so it cannot insert a revision or invalidate redo.
    public func audition(id: String) throws -> [Int] { try region(id).pitches }

    private func region(_ id: String) throws -> ChordRegion {
        guard let region = progression.regions.first(where: { $0.id == id }) else {
            throw MusicError.missingRegion(id)
        }
        return region
    }

    /// Each transaction validates its final state; a failed batch changes nothing.
    /// Intermediate overlap is permitted for atomic multi-region resizes.
    public mutating func apply(_ edits: [ProgressionEdit], vocabulary: ChordVocabulary,
                               solver: VoiceLeadingSolver = VoiceLeadingSolver()) throws {
        var regions = progression.regions
        for edit in edits {
            func index(_ id: String) throws -> Int {
                guard let i = regions.firstIndex(where: { $0.id == id }) else {
                    throw MusicError.missingRegion(id)
                }
                return i
            }
            switch edit {
            case .add(let region): regions.append(region)
            case .delete(let id): regions.remove(at: try index(id))
            case .resize(let id, let start, let length):
                let i = try index(id)
                let old = regions[i]
                regions[i] = try ChordRegion(id: id, chord: old.chord, start: start, length: length, pitches: old.pitches)
            case .swap(let id, let chord):
                let i = try index(id)
                let old = regions[i]
                let previous = regions.filter { $0.id != id && $0.end <= old.start }.max { $0.end < $1.end }
                let pitches = try solver.solve([chord], vocabulary: vocabulary, preceding: previous?.pitches)[0]
                regions[i] = try ChordRegion(id: id, chord: chord, start: old.start, length: old.length, pitches: pitches)
            case .duplicate(let id, let newID, let start):
                let old = regions[try index(id)]
                regions.append(try ChordRegion(id: newID, chord: old.chord, start: start, length: old.length, pitches: old.pitches))
            case .paste(let clipboard, let newID, let start):
                regions.append(try ChordRegion(id: newID, chord: clipboard.chord, start: start,
                                               length: clipboard.length, pitches: clipboard.pitches))
            }
        }
        let next = try Progression(totalSteps: progression.totalSteps, regions: regions, vocabulary: vocabulary)
        guard next != progression else { return }
        undoStack.append(progression)
        progression = next
        redoStack.removeAll()
    }

    @discardableResult public mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(progression)
        progression = previous
        return true
    }

    @discardableResult public mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(progression)
        progression = next
        return true
    }
}
