import Foundation

public enum MusicError: Error, Equatable {
    case invalidVocabulary, unknownQuality(String), invalidChord, invalidPitches
    case invalidSpan, duplicateID, overlap, missingRegion(String)
    case invalidRegister, noVoicing, invalidTempo, invalidSampleRate, timingOverflow
}

/// PROPOSED defaults: SPEC §4, §7.1, §20; DESIGN §2.1 and §3.1.
public enum MusicDefaults {
    public static let stepsPerBar = 16
    public static let stepsPerBeat = 4
    public static let canvasBars = 8
    public static let tempo = 124.0
    public static let key = MusicalKey(tonic: 0, mode: .naturalMinor)
}

public struct Chord: Equatable, Hashable, Sendable {
    public let root: Int
    public let qualityID: String
    public let slashBass: Int?

    public init(root: Int, qualityID: String, slashBass: Int? = nil) throws {
        guard (0...11).contains(root), slashBass.map({ (0...11).contains($0) }) ?? true,
              !qualityID.isEmpty else { throw MusicError.invalidChord }
        self.root = root
        self.qualityID = qualityID
        self.slashBass = slashBass
    }
}

public struct ChordRegion: Equatable, Sendable {
    public let id: String
    public let chord: Chord
    public let start: Int
    public let length: Int
    /// Ascending pitches define the later glide voice indices.
    public let pitches: [Int]
    public var end: Int { start + length }

    public init(id: String, chord: Chord, start: Int, length: Int, pitches: [Int]) throws {
        guard !id.isEmpty, start >= 0, length > 0, start <= Int.max - length else {
            throw MusicError.invalidSpan
        }
        guard !pitches.isEmpty, pitches.allSatisfy({ (0...127).contains($0) }),
              Set(pitches).count == pitches.count else { throw MusicError.invalidPitches }
        self.id = id
        self.chord = chord
        self.start = start
        self.length = length
        self.pitches = pitches.sorted()
    }
}

public struct Progression: Equatable, Sendable {
    public let totalSteps: Int
    public let regions: [ChordRegion]

    public init(totalSteps: Int = MusicDefaults.canvasBars * MusicDefaults.stepsPerBar,
                regions: [ChordRegion] = [], vocabulary: ChordVocabulary) throws {
        guard totalSteps > 0, totalSteps <= MusicDefaults.canvasBars * MusicDefaults.stepsPerBar,
              totalSteps.isMultiple(of: MusicDefaults.stepsPerBar) else { throw MusicError.invalidSpan }
        guard Set(regions.map(\.id)).count == regions.count else { throw MusicError.duplicateID }
        let ordered = regions.sorted { $0.start < $1.start }
        var previousEnd = 0
        for region in ordered {
            guard region.end <= totalSteps else { throw MusicError.invalidSpan }
            guard region.start >= previousEnd else { throw MusicError.overlap }
            let quality = try vocabulary.quality(region.chord.qualityID)
            var expected = Set(quality.intervals.map { ($0 + region.chord.root) % 12 })
            if let bass = region.chord.slashBass {
                expected.insert(bass)
                guard region.pitches.first.map({ $0 % 12 }) == bass else { throw MusicError.invalidPitches }
            }
            guard Set(region.pitches.map { $0 % 12 }) == expected else { throw MusicError.invalidPitches }
            previousEnd = region.end
        }
        self.totalSteps = totalSteps
        self.regions = ordered
    }
}

public struct LoopSpan: Equatable, Sendable {
    public let start: Int
    public let length: Int
    public var end: Int { start + length }

    public init(start: Int = 0, bars: Int = MusicDefaults.canvasBars) throws {
        guard start >= 0, start.isMultiple(of: MusicDefaults.stepsPerBar),
              (1...MusicDefaults.canvasBars).contains(bars),
              start <= MusicDefaults.canvasBars * MusicDefaults.stepsPerBar - bars * MusicDefaults.stepsPerBar
        else { throw MusicError.invalidSpan }
        self.start = start
        self.length = bars * MusicDefaults.stepsPerBar
    }
}
