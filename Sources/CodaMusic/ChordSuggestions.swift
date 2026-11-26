import Foundation

public enum KeyMode: Equatable, Sendable { case major, naturalMinor }

public struct MusicalKey: Sendable {
    public let tonic: Int
    public let mode: KeyMode
    public init(tonic: Int, mode: KeyMode) {
        // Normalization allows transposition without invalid pitch classes.
        self.tonic = (tonic % 12 + 12) % 12
        self.mode = mode
    }
}

public enum HarmonicFunction: String, Sendable { case tonic, subdominant, dominant, borrowed }

public struct ChordSuggestion: Equatable, Sendable {
    public let chord: Chord
    public let function: HarmonicFunction
}

/// Replaceable rule interface for §7.4; has no UI, inference or edit side effects.
public protocol ChordSuggestionProvider: Sendable {
    func suggestions(existing: Chord?, previous: Chord?, key: MusicalKey,
                     vocabulary: ChordVocabulary) throws -> [ChordSuggestion]
}

public struct RuleBasedChordSuggestions: ChordSuggestionProvider {
    public init() {}

    public func function(of chord: Chord, in key: MusicalKey) -> HarmonicFunction {
        let degree = (chord.root - key.tonic + 12) % 12
        if [0, key.mode == .major ? 9 : 8].contains(degree) { return .tonic }
        if [2, 5].contains(degree) { return .subdominant }
        if [7, 11].contains(degree) { return .dominant }
        return .borrowed
    }

    public func suggestions(existing: Chord?, previous: Chord?, key: MusicalKey,
                            vocabulary: ChordVocabulary) throws -> [ChordSuggestion] {
        if let existing {
            let quality = try vocabulary.quality(existing.qualityID)
            // Includes additive qualities from the production vocabulary. Root
            // and slash identity survive every existing-chord suggestion.
            return try quality.suggestions.prefix(3).map { id in
                let chord = try Chord(root: existing.root, qualityID: id, slashBass: existing.slashBass)
                return ChordSuggestion(chord: chord, function: function(of: chord, in: key))
            }
        }
        if let previous { _ = try vocabulary.quality(previous.qualityID) }
        // Ordered functional motion: DOM -> TON, SUB -> DOM, TON -> SUB.
        let priorFunction = previous.map { function(of: $0, in: key) }
        let degrees: [Int]
        switch priorFunction {
        case .some(.dominant): degrees = [0, 5, key.mode == .major ? 9 : 8]
        case .some(.subdominant): degrees = [7, 0, 5]
        default: degrees = [5, 7, 0]
        }
        return try degrees.map { degree in
            let quality: String
            switch degree {
            case 7: quality = "dominant7" // harmonic-minor dominant is intentional.
            case 0, 5: quality = key.mode == .major ? "major7" : "minor7"
            default: quality = key.mode == .major ? "minor7" : "major7"
            }
            _ = try vocabulary.quality(quality)
            let chord = try Chord(root: (key.tonic + degree) % 12, qualityID: quality)
            return ChordSuggestion(chord: chord, function: function(of: chord, in: key))
        }
    }
}
