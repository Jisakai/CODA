import Foundation

public enum PatternError: Error, Equatable {
    case invalidBarCount, invalidRange, invalidSlotCount, invalidSlot
    case emptyID, duplicateRegionID, duplicateStrokeID, missingRegion(String)
    case invalidArrowLevel, nonfiniteLength, invalidChuckSize, invalidSettings
    case freshStrokeIDsRequired
}

/// The single stored arrow magnitude drives drawing, readout and BASE playback.
public struct ArrowLevel: Equatable, Sendable {
    public let value: Int
    public var normalizedLength: Double { Double(value) / 10 }
    public var baseVelocity: Double { normalizedLength }
    public var readout: String { "v\(value * 10)" }

    public init(_ value: Int) throws {
        guard (1...10).contains(value) else { throw PatternError.invalidArrowLevel }
        self.value = value
    }

    /// Zero/negative finite lengths remove a stroke. Clamp BEFORE multiplying
    /// or converting to Int; even greatestFiniteMagnitude must be safe.
    public static func from(normalizedLength: Double) throws -> ArrowLevel? {
        guard normalizedLength.isFinite else { throw PatternError.nonfiniteLength }
        guard normalizedLength > 0 else { return nil }
        let bounded = min(normalizedLength, 1)
        let level = max(1, Int((bounded * 10).rounded(.toNearestOrAwayFromZero)))
        return try ArrowLevel(level)
    }
}

public struct ChuckSize: Equatable, Sendable {
    public let normalizedSize: Double
    public var baseVelocity: Double { normalizedSize }

    public init(_ normalizedSize: Double) throws {
        guard normalizedSize.isFinite, normalizedSize > 0, normalizedSize <= 1 else {
            throw PatternError.invalidChuckSize
        }
        self.normalizedSize = normalizedSize
    }
}

public enum StrokeDirection: Equatable, Sendable { case down, up }
public enum PatternHumanize: Equatable, Sendable { case tight, loose }

public struct PatternStroke: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case arrow(direction: StrokeDirection, level: ArrowLevel)
        case chuck(ChuckSize)

        public var baseVelocity: Double {
            switch self {
            case .arrow(_, let level): return level.baseVelocity
            case .chuck(let size): return size.baseVelocity
            }
        }
    }

    public let id: String
    public let content: Content
    public var baseVelocity: Double { content.baseVelocity }

    public init(id: String, content: Content) throws {
        guard !id.isEmpty else { throw PatternError.emptyID }
        self.id = id
        self.content = content
    }
}

/// Absolute half-open bars [start, end), independent of chord identity.
public struct PatternBarRange: Equatable, Sendable {
    public let start: Int
    public let length: Int
    public var end: Int { start + length }

    public init(start: Int, length: Int) throws {
        let (end, overflow) = start.addingReportingOverflow(length)
        guard start >= 0, length > 0, !overflow, end <= MusicDefaults.canvasBars else {
            throw PatternError.invalidRange
        }
        self.start = start
        self.length = length
    }
}

public enum PatternScope: Equatable, Sendable {
    case wholeLoop

    public func resolve(loop: LoopSpan, barCount: Int) throws -> PatternBarRange {
        guard (1...MusicDefaults.canvasBars).contains(barCount) else {
            throw PatternError.invalidBarCount
        }
        switch self {
        case .wholeLoop:
            let range = try PatternBarRange(start: loop.start / MusicDefaults.stepsPerBar,
                                            length: loop.length / MusicDefaults.stepsPerBar)
            guard range.end <= barCount else { throw PatternError.invalidRange }
            return range
        }
    }
}

/// Provisional feel constants, not listening acceptance. No randomness runs here.
public enum PatternDefaults {
    public static let slotsPerBar = 8
    public static let defaultScope: PatternScope = .wholeLoop
    public static let swing = 0.0
    public static let swingRange = 0.0...1.0
    /// Maximum odd-eighth delay measured in sixteenth-note grid steps.
    public static let maximumSwingDelaySteps = 1.0
    public static let humanize: PatternHumanize = .tight
    public static let spreadMilliseconds = 20.0
    /// TOTAL first-to-last onset duration (singleton spread is zero).
    public static let spreadMillisecondsRange = 0.0...60.0
    public static let presetArrowLevel = 8
    public static let looseAlgorithmVersion: UInt32 = 1
    public static let looseSeed: UInt64 = 0
    public static let looseTimingMilliseconds = 3.0
    public static let looseVelocityDelta = 6.0 / 127.0
    public static let looseDetuneCents = 3.0
    public static let looseFilterDelta = 0.02
    public static let looseEffectiveVelocityRange = 0.01...1.0
    public static let chuckRakeMilliseconds = 12.0
    public static let chuckGateMilliseconds = 40.0
    public static let uncoveredBaseVelocity = 0.8
}

public struct PatternSettings: Equatable, Sendable {
    public let swing: Double
    public let humanize: PatternHumanize
    public let spreadMilliseconds: Double
    /// Later compiler randomness must also include cycle and stable identities.
    public let looseSeed: UInt64
    public var looseAlgorithmVersion: UInt32 { PatternDefaults.looseAlgorithmVersion }

    public init(swing: Double = PatternDefaults.swing,
                humanize: PatternHumanize = PatternDefaults.humanize,
                spreadMilliseconds: Double = PatternDefaults.spreadMilliseconds,
                looseSeed: UInt64 = PatternDefaults.looseSeed) throws {
        guard swing.isFinite, PatternDefaults.swingRange.contains(swing),
              spreadMilliseconds.isFinite,
              PatternDefaults.spreadMillisecondsRange.contains(spreadMilliseconds) else {
            throw PatternError.invalidSettings
        }
        self.swing = swing
        self.humanize = humanize
        self.spreadMilliseconds = spreadMilliseconds
        self.looseSeed = looseSeed
    }
}

public struct PatternRegion: Equatable, Sendable {
    public let id: String
    public let range: PatternBarRange
    /// Eight optional eighth-note strokes, repeated each bar. nil sustains.
    public let slots: [PatternStroke?]
    public let settings: PatternSettings

    public init(id: String, range: PatternBarRange, slots: [PatternStroke?],
                settings: PatternSettings) throws {
        guard !id.isEmpty else { throw PatternError.emptyID }
        guard slots.count == PatternDefaults.slotsPerBar else { throw PatternError.invalidSlotCount }
        let ids = slots.compactMap { $0?.id }
        guard Set(ids).count == ids.count else { throw PatternError.duplicateStrokeID }
        self.id = id
        self.range = range
        self.slots = slots
        self.settings = settings
    }
}

public struct PatternArrangement: Equatable, Sendable {
    public let barCount: Int
    public let regions: [PatternRegion]

    public init(barCount: Int = MusicDefaults.canvasBars, regions: [PatternRegion] = []) throws {
        guard (1...MusicDefaults.canvasBars).contains(barCount) else { throw PatternError.invalidBarCount }
        guard Set(regions.map(\.id)).count == regions.count else { throw PatternError.duplicateRegionID }
        let ids = regions.flatMap { $0.slots.compactMap { $0?.id } }
        guard Set(ids).count == ids.count else { throw PatternError.duplicateStrokeID }
        let ordered = regions.sorted { $0.range.start < $1.range.start }
        var previousEnd = 0
        for region in ordered {
            guard region.range.end <= barCount else { throw PatternError.invalidRange }
            guard region.range.start >= previousEnd else { throw MusicError.overlap }
            previousEnd = region.range.end
        }
        self.barCount = barCount
        self.regions = ordered
    }
}

/// Preset content is data; instances receive identities from their caller.
public struct PatternPreset: Equatable, Sendable {
    public let name: String
    public let slots: [PatternStroke.Content?]

    public init(name: String, slots: [PatternStroke.Content?]) throws {
        guard slots.count == PatternDefaults.slotsPerBar else { throw PatternError.invalidSlotCount }
        self.name = name
        self.slots = slots
    }

    public static let popRock: PatternPreset = {
        // These checked literals cannot fail; no caller input is force-unwrapped.
        let level = try! ArrowLevel(PatternDefaults.presetArrowLevel)
        let down = PatternStroke.Content.arrow(direction: .down, level: level)
        let up = PatternStroke.Content.arrow(direction: .up, level: level)
        return try! PatternPreset(name: "Pop Rock 8-beat", slots: [down, nil, down, up, nil, up, down, up])
    }()

    /// IDs are in occupied-slot order. Arrangement validation checks freshness
    /// against other regions; no UUIDs or hidden identity allocation.
    public func instantiate(id: String, range: PatternBarRange, occupiedStrokeIDs: [String],
                            settings: PatternSettings) throws -> PatternRegion {
        guard occupiedStrokeIDs.count == slots.compactMap({ $0 }).count else {
            throw PatternError.freshStrokeIDsRequired
        }
        var next = 0
        let strokes: [PatternStroke?] = try slots.map { content in
            guard let content else { return nil }
            defer { next += 1 }
            return try PatternStroke(id: occupiedStrokeIDs[next], content: content)
        }
        return try PatternRegion(id: id, range: range, slots: strokes, settings: settings)
    }
}
