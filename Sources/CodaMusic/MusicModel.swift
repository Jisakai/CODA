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
    public static let ticksPerBeat = 480
    public static let ticksPerStep = ticksPerBeat / stepsPerBeat
    public static let tempo = 124.0
    public static let key = MusicalKey(tonic: 0, mode: .naturalMinor)
}

public struct Chord: Codable, Equatable, Hashable, Sendable {
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

public struct RollNote: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    /// Relative to its harmonic region; 480 ticks per quarter note.
    public let startTick: Int
    public let durationTicks: Int
    public let pitch: Int
    public let velocity: Int
    public let slide: Bool
    public var endTick: Int { startTick + durationTicks }

    public init(id: String = UUID().uuidString, startTick: Int = 0, durationTicks: Int,
                pitch: Int, velocity: Int = 102, slide: Bool = false) throws {
        guard !id.isEmpty, startTick >= 0, durationTicks > 0,
              startTick <= Int.max - durationTicks else { throw MusicError.invalidSpan }
        guard (0...127).contains(pitch), (1...127).contains(velocity) else { throw MusicError.invalidPitches }
        self.id = id; self.startTick = startTick; self.durationTicks = durationTicks
        self.pitch = pitch; self.velocity = velocity; self.slide = slide
    }
}

public struct ChordRegion: Codable, Equatable, Sendable {
    public let id: String
    public let chord: Chord
    public let start: Int
    public let length: Int
    /// Ascending pitches define the later glide voice indices.
    public let pitches: [Int]
    public let notes: [RollNote]
    public let detectionUncertain: Bool
    public var end: Int { start + length }

    public init(id: String, chord: Chord, start: Int, length: Int, pitches: [Int],
                notes: [RollNote]? = nil, detectionUncertain: Bool = false) throws {
        guard !id.isEmpty, start >= 0, length > 0, start <= Int.max - length else {
            throw MusicError.invalidSpan
        }
        let (ticks, overflow) = length.multipliedReportingOverflow(by: MusicDefaults.ticksPerStep)
        guard !overflow else { throw MusicError.timingOverflow }
        let values = try notes ?? pitches.map {
            try RollNote(id: "\(id)-\($0)", durationTicks: ticks, pitch: $0)
        }
        guard !values.isEmpty, Set(values.map(\.id)).count == values.count,
              values.allSatisfy({ $0.endTick <= ticks }) else { throw MusicError.invalidPitches }
        for pitch in Set(values.map(\.pitch)) {
            let ordered = values.filter { $0.pitch == pitch }.sorted { $0.startTick < $1.startTick }
            guard zip(ordered, ordered.dropFirst()).allSatisfy({ $0.0.endTick <= $0.1.startTick }) else {
                throw MusicError.overlap
            }
        }
        self.id = id
        self.chord = chord
        self.start = start
        self.length = length
        self.notes = values.sorted { $0.startTick == $1.startTick ? $0.pitch < $1.pitch : $0.startTick < $1.startTick }
        self.pitches = Array(Set(values.map(\.pitch))).sorted()
        self.detectionUncertain = detectionUncertain
    }
}

public struct Progression: Codable, Equatable, Sendable {
    public let totalSteps: Int
    public let regions: [ChordRegion]

    public init(totalSteps: Int = MusicDefaults.canvasBars * MusicDefaults.stepsPerBar,
                regions: [ChordRegion] = [], vocabulary: ChordVocabulary) throws {
        guard totalSteps > 0, totalSteps <= Int.max / MusicDefaults.ticksPerStep,
              totalSteps.isMultiple(of: MusicDefaults.stepsPerBar) else { throw MusicError.invalidSpan }
        guard Set(regions.map(\.id)).count == regions.count else { throw MusicError.duplicateID }
        let ordered = regions.sorted { $0.start < $1.start }
        var previousEnd = 0
        for region in ordered {
            guard region.end <= totalSteps else { throw MusicError.invalidSpan }
            guard region.start >= previousEnd else { throw MusicError.overlap }
            _ = try vocabulary.quality(region.chord.qualityID)
            // Manual note shapes may be unknown. Identity is a retained label,
            // never a constraint that prevents the owner from editing pitches.
            previousEnd = region.end
        }
        self.totalSteps = totalSteps
        self.regions = ordered
    }
}

public struct LoopSpan: Codable, Equatable, Sendable {
    public let start: Int
    public let length: Int
    public var end: Int { start + length }

    public init(start: Int = 0, bars: Int = MusicDefaults.canvasBars) throws {
        let (length, overflow) = bars.multipliedReportingOverflow(by: MusicDefaults.stepsPerBar)
        guard start >= 0, start.isMultiple(of: MusicDefaults.stepsPerBar), bars > 0,
              !overflow, start <= Int.max - length,
              start + length <= Int.max / MusicDefaults.ticksPerStep
        else { throw MusicError.invalidSpan }
        self.start = start
        self.length = length
    }
}
