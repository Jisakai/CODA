import Foundation

public enum ProjectDocumentError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidDocument(String)
}

public struct LayerSynthState: Codable, Equatable, Hashable, Sendable {
    public var presetID: String
    public var volume: Double
    public var filterCutoff: Double
    public var resonance: Double
    public var attack: Double
    public var release: Double
    public var wobble: Double
    public var warmth: Double
    public var glide: Double
    public var muted: Bool

    public init(
        presetID: String = "warmPad",
        volume: Double = 0.8,
        filterCutoff: Double = 0.72,
        resonance: Double = 0.18,
        attack: Double = 0.08,
        release: Double = 0.35,
        wobble: Double = 0.25,
        warmth: Double = 0.55,
        glide: Double = 0.0,
        muted: Bool = false
    ) {
        self.presetID = presetID
        self.volume = volume
        self.filterCutoff = filterCutoff
        self.resonance = resonance
        self.attack = attack
        self.release = release
        self.wobble = wobble
        self.warmth = warmth
        self.glide = glide
        self.muted = muted
    }

    public static let defaultChords = LayerSynthState(presetID: "warmPad", volume: 0.82, glide: 0.0)
    public static let defaultBass = LayerSynthState(presetID: "subBass", volume: 0.85, filterCutoff: 0.45, attack: 0.02, release: 0.2, glide: 0.15)
    public static let defaultMelody = LayerSynthState(presetID: "pluckedKeys", volume: 0.78, filterCutoff: 0.8, attack: 0.01, release: 0.28, glide: 0.05)
}

public struct SharedFXState: Codable, Equatable, Hashable, Sendable {
    public var chorusMix: Double
    public var delayMix: Double
    public var delayFeedback: Double
    public var delayTimeSteps: Double
    public var reverbMix: Double
    public var reverbDecay: Double

    public init(
        chorusMix: Double = 0.16,
        delayMix: Double = 0.18,
        delayFeedback: Double = 0.32,
        delayTimeSteps: Double = 3.0,
        reverbMix: Double = 0.24,
        reverbDecay: Double = 0.55
    ) {
        self.chorusMix = chorusMix
        self.delayMix = delayMix
        self.delayFeedback = delayFeedback
        self.delayTimeSteps = delayTimeSteps
        self.reverbMix = reverbMix
        self.reverbDecay = reverbDecay
    }

    private enum CodingKeys: String, CodingKey {
        case chorusMix, delayMix, delayFeedback, delayTimeSteps, reverbMix, reverbDecay
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chorusMix = try c.decodeIfPresent(Double.self, forKey: .chorusMix) ?? 0.16
        delayMix = try c.decodeIfPresent(Double.self, forKey: .delayMix) ?? 0.18
        delayFeedback = try c.decodeIfPresent(Double.self, forKey: .delayFeedback) ?? 0.32
        delayTimeSteps = try c.decodeIfPresent(Double.self, forKey: .delayTimeSteps) ?? 3.0
        reverbMix = try c.decodeIfPresent(Double.self, forKey: .reverbMix) ?? 0.24
        reverbDecay = try c.decodeIfPresent(Double.self, forKey: .reverbDecay) ?? 0.55
    }
}

public struct MixerAndSynthState: Codable, Equatable, Hashable, Sendable {
    public var chords: LayerSynthState
    public var bass: LayerSynthState
    public var melody: LayerSynthState
    public var sharedFX: SharedFXState

    public init(
        chords: LayerSynthState = .defaultChords,
        bass: LayerSynthState = .defaultBass,
        melody: LayerSynthState = .defaultMelody,
        sharedFX: SharedFXState = SharedFXState()
    ) {
        self.chords = chords
        self.bass = bass
        self.melody = melody
        self.sharedFX = sharedFX
    }

    public var mutedLayers: Set<MusicLayer> {
        var set = Set<MusicLayer>()
        if chords.muted { set.insert(.chords) }
        if bass.muted { set.insert(.bass) }
        if melody.muted { set.insert(.melody) }
        return set
    }
}

public struct ViewportState: Codable, Equatable, Hashable, Sendable {
    public var activeLayer: MusicLayer
    public var scrollStep: Double
    public var horizontalZoom: Double
    public var verticalScrollPitch: Double
    public var verticalZoom: Double
    public var gridSnapEnabled: Bool
    public var showNoteLabels: Bool

    public init(
        activeLayer: MusicLayer = .chords,
        scrollStep: Double = 0.0,
        horizontalZoom: Double = 1.0,
        verticalScrollPitch: Double = 60.0,
        verticalZoom: Double = 1.0,
        gridSnapEnabled: Bool = true,
        showNoteLabels: Bool = false
    ) {
        self.activeLayer = activeLayer
        self.scrollStep = scrollStep
        self.horizontalZoom = horizontalZoom
        self.verticalScrollPitch = verticalScrollPitch
        self.verticalZoom = verticalZoom
        self.gridSnapEnabled = gridSnapEnabled
        self.showNoteLabels = showNoteLabels
    }
}

public struct ProjectABSnapshot: Codable, Equatable, Sendable {
    public var label: String
    public var capturedAt: Date
    public var tempo: Double
    public var key: MusicalKey
    public var loopSpan: LoopSpan
    public var arrangementTotalSteps: Int
    public var chordRegions: [ChordRegion]
    public var bassNotes: [BassNote]
    public var melodyNotes: [MelodyNote]
    public var patternArrangement: PatternArrangement
    public var synthState: MixerAndSynthState

    public init(
        label: String = "A",
        capturedAt: Date = Date(),
        tempo: Double,
        key: MusicalKey,
        loopSpan: LoopSpan,
        arrangementTotalSteps: Int,
        chordRegions: [ChordRegion],
        bassNotes: [BassNote],
        melodyNotes: [MelodyNote],
        patternArrangement: PatternArrangement,
        synthState: MixerAndSynthState
    ) {
        self.label = label
        self.capturedAt = capturedAt
        self.tempo = tempo
        self.key = key
        self.loopSpan = loopSpan
        self.arrangementTotalSteps = arrangementTotalSteps
        self.chordRegions = chordRegions
        self.bassNotes = bassNotes
        self.melodyNotes = melodyNotes
        self.patternArrangement = patternArrangement
        self.synthState = synthState
    }
}

/// Versioned JSON project persistence document (SPEC §19 + Nov 28 save hub).
public struct CodaProjectDocument: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var tempo: Double
    public var key: MusicalKey
    public var loopSpan: LoopSpan
    public var looping: Bool
    public var arrangementTotalSteps: Int
    public var chordRegions: [ChordRegion]
    public var bassNotes: [BassNote]
    public var melodyNotes: [MelodyNote]
    public var patternArrangement: PatternArrangement
    public var synthState: MixerAndSynthState
    public var viewport: ViewportState
    public var abSnapshot: ProjectABSnapshot?

    public init(
        schemaVersion: Int = CodaProjectDocument.currentSchemaVersion,
        id: String = UUID().uuidString,
        name: String = "Untitled Sketch",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        tempo: Double = MusicDefaults.tempo,
        key: MusicalKey = MusicDefaults.key,
        loopSpan: LoopSpan = try! LoopSpan(),
        looping: Bool = true,
        arrangementTotalSteps: Int = MusicDefaults.canvasBars * MusicDefaults.stepsPerBar,
        chordRegions: [ChordRegion] = [],
        bassNotes: [BassNote] = [],
        melodyNotes: [MelodyNote] = [],
        patternArrangement: PatternArrangement = try! PatternArrangement(),
        synthState: MixerAndSynthState = MixerAndSynthState(),
        viewport: ViewportState = ViewportState(),
        abSnapshot: ProjectABSnapshot? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.tempo = tempo
        self.key = key
        self.loopSpan = loopSpan
        self.looping = looping
        self.arrangementTotalSteps = arrangementTotalSteps
        self.chordRegions = chordRegions
        self.bassNotes = bassNotes
        self.melodyNotes = melodyNotes
        self.patternArrangement = patternArrangement
        self.synthState = synthState
        self.viewport = viewport
        self.abSnapshot = abSnapshot
    }

    public func captureABSnapshot(label: String = "A", at date: Date = Date()) -> ProjectABSnapshot {
        ProjectABSnapshot(
            label: label,
            capturedAt: date,
            tempo: tempo,
            key: key,
            loopSpan: loopSpan,
            arrangementTotalSteps: arrangementTotalSteps,
            chordRegions: chordRegions,
            bassNotes: bassNotes,
            melodyNotes: melodyNotes,
            patternArrangement: patternArrangement,
            synthState: synthState
        )
    }

    public func makeProgression(vocabulary: ChordVocabulary) throws -> Progression {
        try Progression(totalSteps: arrangementTotalSteps, regions: chordRegions, vocabulary: vocabulary)
    }

    public func makeBassTrack() throws -> BassTrack {
        try BassTrack(notes: bassNotes)
    }

    public func makeMelodyTrack() throws -> MelodyTrack {
        try MelodyTrack(notes: melodyNotes)
    }

    public func encodeJSON(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decodeJSON(_ data: Data) throws -> CodaProjectDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(CodaProjectDocument.self, from: data)
        guard document.schemaVersion >= 1, document.schemaVersion <= currentSchemaVersion else {
            throw ProjectDocumentError.unsupportedSchemaVersion(document.schemaVersion)
        }
        guard !document.id.isEmpty else {
            throw ProjectDocumentError.invalidDocument("Empty project id")
        }
        guard document.tempo.isFinite, document.tempo > 0 else {
            throw ProjectDocumentError.invalidDocument("Invalid tempo")
        }
        guard document.arrangementTotalSteps > 0,
              document.arrangementTotalSteps.isMultiple(of: MusicDefaults.stepsPerBar) else {
            throw ProjectDocumentError.invalidDocument("Invalid arrangementTotalSteps")
        }
        return document
    }
}
