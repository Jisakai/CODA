import Foundation

public enum PatternCompilerError: Error, Equatable {
    case dimensionMismatch
    case pitchCapacity, eventCapacity, simultaneousCapacity, heldCapacity
    case tokenExhausted, invalidEventSequence
}

public enum PatternCompilerLimits {
    public static let pitchesPerChord = 12
    public static let events = 3072
    public static let simultaneousEvents = 32
    public static let heldNotes = 12
}

// Separate namespaces. Values are bounded, nonzero and LOCAL to one compiled
// cycle, NOT runtime generations. Slice 2 must qualify them with a nonwrapping
// prepare epoch, plan generation and cycle; restore/audition need fresh ownership.
public struct PatternHarmonicToken: Equatable, Hashable, Sendable { public let rawValue: UInt16 }
public struct PatternOccurrenceToken: Equatable, Hashable, Sendable { public let rawValue: UInt16 }
public struct PatternNoteToken: Equatable, Hashable, Sendable { public let rawValue: UInt16 }

public enum PatternAttackMode: Equatable, Sendable { case ordinary, chuck }

public struct PatternHarmonicRegion: Equatable, Sendable {
    public let token: PatternHarmonicToken
    public let regionIndex: Int
    public let regionID: String
}

public struct PatternOccurrence: Equatable, Sendable {
    public let token: PatternOccurrenceToken
    public let harmonicToken: PatternHarmonicToken
    /// Absolute arrangement coordinates, not rebased pattern phase.
    public let nominalStep: Int
    public let ownershipStartStep: Int
    public let ownershipEndStep: Int
    /// nil identifies an uncovered simultaneous block attack.
    public let patternRegionID: String?
    public let strokeID: String?
}

public struct PatternNoteEvent: Equatable, Sendable {
    public let sampleOffset: Int64
    public let kind: NoteEventKind
    public let pitch: UInt8
    public let ascendingRank: Int
    /// Directional position in the rake; independent of ascending harmonic rank.
    public let onsetOrdinal: Int
    public let harmonicToken: PatternHarmonicToken
    public let occurrenceToken: PatternOccurrenceToken
    public let instanceToken: PatternNoteToken
    public let baseVelocity: Double
    public let effectiveVelocity: Double
    public let timingJitterSeconds: Double
    public let detuneCents: Double
    public let filterDelta: Double
    public let attackMode: PatternAttackMode
    public let layer: MusicLayer
    /// Control-side continuation identity; never published as a Swift object.
    public var continuationKey: String? = nil
    public var continuesFromPrevious = false
    public var continuesIntoNext = false
    public var slide = false

    public init(
        sampleOffset: Int64,
        kind: NoteEventKind,
        pitch: UInt8,
        ascendingRank: Int,
        onsetOrdinal: Int,
        harmonicToken: PatternHarmonicToken,
        occurrenceToken: PatternOccurrenceToken,
        instanceToken: PatternNoteToken,
        baseVelocity: Double,
        effectiveVelocity: Double,
        timingJitterSeconds: Double,
        detuneCents: Double,
        filterDelta: Double,
        attackMode: PatternAttackMode,
        layer: MusicLayer = .chords,
        continuationKey: String? = nil,
        continuesFromPrevious: Bool = false,
        continuesIntoNext: Bool = false,
        slide: Bool = false
    ) {
        self.sampleOffset = sampleOffset
        self.kind = kind
        self.pitch = pitch
        self.ascendingRank = ascendingRank
        self.onsetOrdinal = onsetOrdinal
        self.harmonicToken = harmonicToken
        self.occurrenceToken = occurrenceToken
        self.instanceToken = instanceToken
        self.baseVelocity = baseVelocity
        self.effectiveVelocity = effectiveVelocity
        self.timingJitterSeconds = timingJitterSeconds
        self.detuneCents = detuneCents
        self.filterDelta = filterDelta
        self.attackMode = attackMode
        self.layer = layer
        self.continuationKey = continuationKey
        self.continuesFromPrevious = continuesFromPrevious
        self.continuesIntoNext = continuesIntoNext
        self.slide = slide
    }
}

/// Immutable OFF-thread storage only. Never publish through the step-only bridge.
public struct CompiledPatternLoop: Equatable, Sendable {
    public let cycleIndex: Int64
    public let originSample: Int64
    public let sampleCount: Int64
    public let looseAlgorithmVersion: UInt32
    public let harmonics: [PatternHarmonicRegion]
    /// Includes nominal occurrences whose notes were clipped/cancelled/coalesced.
    public let occurrences: [PatternOccurrence]
    public let events: [PatternNoteEvent]
}

public enum PatternCompilation: Equatable, Sendable {
    case legacy(CompiledLoop)
    case pattern(CompiledPatternLoop)
}

public enum PatternEventCompiler {
    public static func compile(_ progression: Progression, arrangement: PatternArrangement,
                               tempo: Double, sampleRate: Double, loop: LoopSpan,
                               cycleIndex: Int64 = 0, forcePerformance: Bool = false,
                               carryIn: Bool = false, carryOut: Bool = false) throws -> PatternCompilation {
        // This precondition deliberately precedes EVERY other error/delegation.
        let (steps, overflow) = arrangement.barCount.multipliedReportingOverflow(by: MusicDefaults.stepsPerBar)
        guard !overflow, steps == progression.totalSteps else { throw PatternCompilerError.dimensionMismatch }
        let coverage = arrangement.regions.filter {
            $0.range.start * MusicDefaults.stepsPerBar < loop.end &&
            $0.range.end * MusicDefaults.stepsPerBar > loop.start
        }
        let needsRollScheduling = loop.length > 128 || progression.regions.count > 128 || progression.regions.contains { region in
            region.notes.count != region.pitches.count || region.notes.contains {
                $0.startTick != 0 || $0.durationTicks != region.length * MusicDefaults.ticksPerStep || $0.velocity != 102 || $0.slide
            }
        }
        guard forcePerformance || !coverage.isEmpty || needsRollScheduling else {
            return .legacy(try NoteEventCompiler.compile(progression, tempo: tempo,
                sampleRate: sampleRate, loop: loop, cycleIndex: cycleIndex))
        }
        let clock = try Clock(progression: progression, tempo: tempo, rate: sampleRate,
                              loop: loop, cycle: cycleIndex)
        var harmonics: [PatternHarmonicRegion] = []
        var occurrences: [PatternOccurrence] = []
        var attacks: [Attack] = []

        // Nonoverlapping chord/coverage intersections form disjoint ownership
        // intervals. No onset, sustain or jitter may escape one such interval.
        for (regionIndex, chord) in progression.regions.enumerated() {
            let start = max(chord.start, loop.start)
            let end = min(chord.end, loop.end)
            guard start < end else { continue }
            let harmonic = PatternHarmonicToken(rawValue: try token(harmonics.count + 1))
            harmonics.append(PatternHarmonicRegion(token: harmonic, regionIndex: regionIndex, regionID: chord.id))
            var cuts = [start, end]
            for pattern in coverage {
                for boundary in [pattern.range.start * MusicDefaults.stepsPerBar,
                                 pattern.range.end * MusicDefaults.stepsPerBar] where boundary > start && boundary < end {
                    cuts.append(boundary)
                }
            }
            cuts = Array(Set(cuts)).sorted()
            for i in 0..<(cuts.count - 1) {
                let lo = cuts[i], hi = cuts[i + 1]
                let loTime = clock.absolute(step: lo - loop.start)
                let hiTime = clock.absolute(step: hi - loop.start)
                let loSample = try clock.offset(absolute: loTime)
                let hiSample = try clock.offset(absolute: hiTime)
                guard hiSample > loSample else { throw MusicError.timingOverflow }
                let pattern = coverage.first {
                    $0.range.start * MusicDefaults.stepsPerBar <= lo && lo < $0.range.end * MusicDefaults.stepsPerBar
                }
                if pattern == nil {
                    for note in chord.notes {
                        let startTick = max((lo - chord.start) * MusicDefaults.ticksPerStep, note.startTick)
                        let endTick = min((hi - chord.start) * MusicDefaults.ticksPerStep, note.endTick)
                        guard endTick > startTick else { continue }
                        let onStep = Double(chord.start - loop.start) + Double(startTick) / Double(MusicDefaults.ticksPerStep)
                        let offStep = Double(chord.start - loop.start) + Double(endTick) / Double(MusicDefaults.ticksPerStep)
                        let on = try clock.offset(absolute: clock.absolute(step: onStep))
                        let off = try clock.offset(absolute: clock.absolute(step: offStep))
                        let occurrence = PatternOccurrence(token: PatternOccurrenceToken(rawValue: try token(occurrences.count + 1)),
                            harmonicToken: harmonic, nominalStep: chord.start + startTick / MusicDefaults.ticksPerStep,
                            ownershipStartStep: lo, ownershipEndStep: hi, patternRegionID: nil, strokeID: nil)
                        occurrences.append(occurrence)
                        let rank = (chord.pitches.firstIndex(of: note.pitch) ?? 0) % PatternCompilerLimits.heldNotes
                        let velocity = Double(note.velocity) / 127
                        var event = PatternNoteEvent(sampleOffset: on, kind: .noteOn, pitch: UInt8(note.pitch),
                            ascendingRank: rank, onsetOrdinal: rank, harmonicToken: harmonic, occurrenceToken: occurrence.token,
                            instanceToken: PatternNoteToken(rawValue: try token(attacks.count + 1)), baseVelocity: velocity,
                            effectiveVelocity: velocity, timingJitterSeconds: 0, detuneCents: 0, filterDelta: 0, attackMode: .ordinary)
                        event.continuationKey = "note:\(chord.id.utf8.count):\(chord.id):\(note.id)"
                        event.continuesFromPrevious = carryIn && chord.start * MusicDefaults.ticksPerStep + note.startTick < loop.start * MusicDefaults.ticksPerStep
                        event.continuesIntoNext = carryOut && chord.start * MusicDefaults.ticksPerStep + note.endTick > loop.end * MusicDefaults.ticksPerStep
                        event.slide = note.slide
                        attacks.append(Attack(event: event, occurrence: occurrence, end: off))
                    }
                    continue
                }
                var anchors = Array(stride(from: ((lo + 1) / 2) * 2, to: hi, by: 2))
                // A bar-sized playback window may begin in the sustain of an
                // earlier stroke. Search at most one eight-slot repetition.
                if carryIn, lo == loop.start, let pattern {
                    let first = max(chord.start, pattern.range.start * MusicDefaults.stepsPerBar)
                    let candidate = ((lo - 1) / 2) * 2
                    if candidate >= first {
                        for anchor in stride(from: candidate, through: max(first, candidate - 14), by: -2) {
                            if let stroke = pattern.slots[(anchor % MusicDefaults.stepsPerBar) / 2] {
                                // Chucks are percussive dead-string mutes: they damp prior sustain
                                // and must never re-trigger across bar boundaries.
                                if case .chuck = stroke.content { break }
                                anchors.insert(anchor, at: 0); break
                            }
                        }
                    }
                }
                for anchor in anchors {
                    let slot = (anchor % MusicDefaults.stepsPerBar) / 2
                    let stroke = pattern?.slots[slot]
                    if pattern != nil && stroke == nil { continue }
                    let occurrence = PatternOccurrence(token: PatternOccurrenceToken(rawValue: try token(occurrences.count + 1)),
                        harmonicToken: harmonic, nominalStep: anchor, ownershipStartStep: lo, ownershipEndStep: hi,
                        patternRegionID: pattern?.id, strokeID: stroke?.id)
                    occurrences.append(occurrence)
                    let settings = pattern?.settings
                    let loose = settings?.humanize == .loose
                    var random = StableNoise(seed: settings?.looseSeed ?? 0, cycle: cycleIndex,
                        chord: chord.id, pattern: pattern?.id ?? "", stroke: stroke?.id ?? "",
                        bar: anchor / MusicDefaults.stepsPerBar, slot: slot)
                    let jitter = loose ? random.value(channel: 0) * PatternDefaults.looseTimingMilliseconds / 1000 : 0
                    let swing = slot.isMultiple(of: 2) ? 0 : (settings?.swing ?? 0) * PatternDefaults.maximumSwingDelaySteps
                    let base = stroke?.baseVelocity ?? PatternDefaults.uncoveredBaseVelocity
                    let mode: PatternAttackMode
                    let ranks: [Int]
                    let anchorTick = (anchor - chord.start) * MusicDefaults.ticksPerStep
                    let soundingPitches = Array(Set(chord.notes.filter {
                        $0.startTick <= anchorTick && $0.endTick > anchorTick
                    }.map(\.pitch))).sorted()
                    guard soundingPitches.count <= PatternCompilerLimits.pitchesPerChord else { throw PatternCompilerError.pitchCapacity }
                    switch stroke?.content {
                    case .some(.chuck(_)):
                        mode = .chuck
                        ranks = Array(soundingPitches.indices)
                    case .some(.arrow(let direction, _)):
                        mode = .ordinary
                        ranks = direction == .down ? Array(soundingPitches.indices) : Array(soundingPitches.indices.reversed())
                    case .none:
                        mode = .ordinary
                        ranks = Array(soundingPitches.indices)
                    }
                    let spread = mode == .chuck ? PatternDefaults.chuckRakeMilliseconds : (settings?.spreadMilliseconds ?? 0)
                    for (ordinal, rank) in ranks.enumerated() {
                        let delay = onsetSpreadMilliseconds(ordinal: ordinal, noteCount: ranks.count, total: spread) / 1000
                        // ONE rounding of absolute time, with shared jitter and
                        // total spread already included; never rounded-offset + jitter.
                        let raw = clock.absolute(step: Double(anchor - loop.start) + swing) +
                            (jitter + delay) * sampleRate
                        guard raw.isFinite else { throw MusicError.timingOverflow }
                    let adjusted = max(loTime, raw)
                        guard adjusted < hiTime else { continue }
                        let on = try clock.offset(absolute: adjusted)
                        guard on < hiSample else { continue }
                        let pitch = soundingPitches[rank]
                        random.note(pitch)
                        let velocityRange = PatternDefaults.looseEffectiveVelocityRange
                        let velocity = loose ? min(velocityRange.upperBound, max(velocityRange.lowerBound,
                            base + random.value(channel: 1) * PatternDefaults.looseVelocityDelta)) : base
                        let detune = loose ? random.value(channel: 2) * PatternDefaults.looseDetuneCents : 0
                        let filter = loose ? random.value(channel: 3) * PatternDefaults.looseFilterDelta : 0
                        let gate = mode == .chuck ? try clock.offset(absolute:
                            min(hiTime, adjusted + PatternDefaults.chuckGateMilliseconds / 1000 * sampleRate)) : hiSample
                        var event = PatternNoteEvent(sampleOffset: on, kind: .noteOn, pitch: UInt8(pitch),
                            ascendingRank: rank, onsetOrdinal: ordinal, harmonicToken: harmonic,
                            occurrenceToken: occurrence.token, instanceToken: PatternNoteToken(rawValue: try token(attacks.count + 1)),
                            baseVelocity: base, effectiveVelocity: velocity, timingJitterSeconds: jitter,
                            detuneCents: detune, filterDelta: filter, attackMode: mode)
                        event.continuationKey = "stroke:\(chord.id.utf8.count):\(chord.id):\(pattern?.id ?? ""):\(anchor):\(pitch)"
                        event.continuesFromPrevious = carryIn && anchor < loop.start && mode == .ordinary
                        let semanticEnd = min(chord.end, pattern?.range.end.multipliedReportingOverflow(by: MusicDefaults.stepsPerBar).partialValue ?? chord.end)
                        event.continuesIntoNext = carryOut && semanticEnd > loop.end && mode == .ordinary
                        attacks.append(Attack(event: event, occurrence: occurrence, end: gate))
                    }
                }
            }
        }

        attacks.sort { ordered($0.event, $1.event) }
        // Resolve each complete sample group's collisions BEFORE deriving its
        // chuck cutoff. A candidate superseded by an ordinary attack must not
        // damp or cancel anything. The cutoff persists for pending older notes.
        var retained: [Attack] = []
        var dampings: [Int64] = []
        var seenChucks = Set<PatternOccurrenceToken>()
        var cutoff: UInt16 = 0
        var index = 0
        while index < attacks.count {
            var end = index + 1
            let sample = attacks[index].event.sampleOffset
            while end < attacks.count && attacks[end].event.sampleOffset == sample { end += 1 }
            // Sorted oldest -> newest nominal occurrence, then ordinal/token;
            // overwrite retains the required latest winner in each collision.
            var winners: [Collision: Attack] = [:]
            for attack in attacks[index..<end] where attack.event.occurrenceToken.rawValue >= cutoff {
                winners[Collision(harmonic: attack.event.harmonicToken,
                    start: attack.occurrence.ownershipStartStep, end: attack.occurrence.ownershipEndStep,
                    pitch: attack.event.pitch, sample: sample)] = attack
            }
            let group = winners.values.sorted { ordered($0.event, $1.event) }
            if let newest = group.filter({ $0.event.attackMode == .chuck }).map({ $0.event.occurrenceToken.rawValue }).max() {
                cutoff = max(cutoff, newest)
            }
            for attack in group where attack.event.occurrenceToken.rawValue >= cutoff {
                if attack.event.attackMode == .chuck && seenChucks.insert(attack.event.occurrenceToken).inserted {
                    dampings.append(sample)
                }
                retained.append(attack)
            }
            index = end
        }

        // Only retained winners now participate in lifetime/capacity checks.
        var nextPitch: [UInt8: Int64] = [:]
        var events: [PatternNoteEvent] = []
        for attack in retained.reversed() {
            var on = attack.event
            var off = min(attack.end, nextPitch[on.pitch] ?? clock.count)
            if let damp = dampings.first(where: { $0 > on.sampleOffset }) { off = min(off, damp) }
            guard off > on.sampleOffset else { throw MusicError.timingOverflow }
            on.continuesIntoNext = on.continuesIntoNext && off == clock.count
            events.append(on)
            events.append(on.ending(at: off))
            nextPitch[on.pitch] = on.sampleOffset
        }
        events.sort(by: ordered)
        try validate(events, sampleCount: clock.count)
        return .pattern(CompiledPatternLoop(cycleIndex: cycleIndex, originSample: clock.origin,
            sampleCount: clock.count, looseAlgorithmVersion: PatternDefaults.looseAlgorithmVersion,
            harmonics: harmonics, occurrences: occurrences, events: events))
    }

    private struct Attack {
        let event: PatternNoteEvent
        let occurrence: PatternOccurrence
        let end: Int64
    }

    private struct Collision: Hashable {
        let harmonic: PatternHarmonicToken
        let start: Int
        let end: Int
        let pitch: UInt8
        let sample: Int64
    }

    fileprivate static func token(_ value: Int) throws -> UInt16 {
        guard value > 0, let result = UInt16(exactly: value) else { throw PatternCompilerError.tokenExhausted }
        return result
    }

    static func onsetSpreadMilliseconds(ordinal: Int, noteCount: Int, total: Double) -> Double {
        noteCount > 1 ? total * Double(ordinal) / Double(noteCount - 1) : 0
    }

    static func checkCapacities(eventCount: Int, simultaneous: Int, held: Int) throws {
        guard eventCount <= PatternCompilerLimits.events else { throw PatternCompilerError.eventCapacity }
        guard simultaneous <= PatternCompilerLimits.simultaneousEvents else { throw PatternCompilerError.simultaneousCapacity }
        guard held <= PatternCompilerLimits.heldNotes else { throw PatternCompilerError.heldCapacity }
    }

    private static func ordered(_ a: PatternNoteEvent, _ b: PatternNoteEvent) -> Bool {
        if a.sampleOffset != b.sampleOffset { return a.sampleOffset < b.sampleOffset }
        if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
        if a.occurrenceToken != b.occurrenceToken { return a.occurrenceToken.rawValue < b.occurrenceToken.rawValue }
        if a.onsetOrdinal != b.onsetOrdinal { return a.onsetOrdinal < b.onsetOrdinal }
        return a.instanceToken.rawValue < b.instanceToken.rawValue
    }

    /// Production admission check, internal so tests can reach exact/one-over
    /// limits that disjoint eight-bar model ownership makes unreachable today.
    /// This is compiler validation, NOT native queue/admission/restore safety.
    static func validate(_ events: [PatternNoteEvent], sampleCount: Int64) throws {
        try checkCapacities(eventCount: events.count, simultaneous: 0, held: 0)
        var held: [PatternNoteToken: PatternNoteEvent] = [:]
        var used = Set<PatternNoteToken>()
        var previous: PatternNoteEvent?
        var group = 0
        for event in events {
            if let previous, ordered(event, previous) { throw PatternCompilerError.invalidEventSequence }
            group = previous?.sampleOffset == event.sampleOffset ? group + 1 : 1
            try checkCapacities(eventCount: events.count, simultaneous: group, held: held.count)
            guard event.sampleOffset >= 0, event.sampleOffset <= sampleCount else { throw PatternCompilerError.invalidEventSequence }
            switch event.kind {
            case .noteOn:
                guard event.sampleOffset < sampleCount, used.insert(event.instanceToken).inserted else {
                    throw PatternCompilerError.invalidEventSequence
                }
                held[event.instanceToken] = event
                try checkCapacities(eventCount: events.count, simultaneous: group, held: held.count)
            case .noteOff:
                guard let on = held.removeValue(forKey: event.instanceToken),
                      on.sampleOffset < event.sampleOffset, on.ending(at: event.sampleOffset) == event else {
                    throw PatternCompilerError.invalidEventSequence
                }
            }
            previous = event
        }
        guard held.isEmpty else { throw PatternCompilerError.invalidEventSequence }
    }

    fileprivate struct Clock {
        let start: Int64
        let samplesPerStep: Double
        let origin: Int64
        let count: Int64

        init(progression: Progression, tempo: Double, rate: Double, loop: LoopSpan, cycle: Int64) throws {
            guard tempo.isFinite, tempo > 0 else { throw MusicError.invalidTempo }
            guard rate.isFinite, rate > 0 else { throw MusicError.invalidSampleRate }
            guard loop.end <= progression.totalSteps, cycle >= 0 else { throw MusicError.invalidSpan }
            let (start, overflow) = cycle.multipliedReportingOverflow(by: Int64(loop.length))
            let (end, endOverflow) = start.addingReportingOverflow(Int64(loop.length))
            guard !overflow, !endOverflow, end <= 9_007_199_254_740_992 else { throw MusicError.timingOverflow }
            let scale = rate * 60 / tempo / Double(MusicDefaults.stepsPerBeat)
            let origin = try Self.round(Double(start) * scale)
            let terminal = try Self.round(Double(end) * scale)
            guard terminal > origin else { throw MusicError.timingOverflow }
            self.start = start
            self.samplesPerStep = scale
            self.origin = origin
            self.count = terminal - origin
        }

        func absolute(step: Int) -> Double { absolute(step: Double(step)) }
        func absolute(step: Double) -> Double { (Double(start) + step) * samplesPerStep }
        func offset(absolute: Double) throws -> Int64 { try Self.round(absolute) - origin }
        private static func round(_ value: Double) throws -> Int64 {
            let rounded = value.rounded(.toNearestOrAwayFromZero)
            guard rounded.isFinite, rounded >= 0, rounded < Double(Int64.max) else { throw MusicError.timingOverflow }
            return Int64(rounded)
        }
    }

    /// Version 1: length-delimited UTF-8 FNV-1a, little-endian UInt64 fields,
    /// followed by SplitMix64 finalization per channel. Wrapping is intentional
    /// for HASH arithmetic only; identity allocation above never wraps.
    private struct StableNoise {
        private var hash: UInt64 = 14_695_981_039_346_656_037
        private var noteHash: UInt64 = 0

        init(seed: UInt64, cycle: Int64, chord: String, pattern: String, stroke: String, bar: Int, slot: Int) {
            number(UInt64(PatternDefaults.looseAlgorithmVersion))
            number(seed)
            number(UInt64(cycle))
            for string in [chord, pattern, stroke] {
                number(UInt64(string.utf8.count))
                for byte in string.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            }
            number(UInt64(bar))
            number(UInt64(slot))
            noteHash = hash
        }

        private mutating func number(_ value: UInt64) {
            for shift in stride(from: 0, to: 64, by: 8) {
                hash = (hash ^ ((value >> shift) & 255)) &* 1_099_511_628_211
            }
        }

        mutating func note(_ pitch: Int) {
            let strokeHash = hash
            number(UInt64(pitch))
            noteHash = hash
            hash = strokeHash
        }

        func value(channel: UInt64) -> Double {
            var value = (channel == 0 ? hash : noteHash) &+ (channel &+ 1) &* 0x9e3779b97f4a7c15
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            value ^= value >> 31
            return Double(value >> 11) / 9_007_199_254_740_992 * 2 - 1
        }
    }
}

extension PatternNoteEvent {
    fileprivate func ending(at sample: Int64) -> PatternNoteEvent {
        PatternNoteEvent(
            sampleOffset: sample, kind: .noteOff, pitch: pitch,
            ascendingRank: ascendingRank, onsetOrdinal: onsetOrdinal, harmonicToken: harmonicToken,
            occurrenceToken: occurrenceToken, instanceToken: instanceToken, baseVelocity: baseVelocity,
            effectiveVelocity: effectiveVelocity, timingJitterSeconds: timingJitterSeconds,
            detuneCents: detuneCents, filterDelta: filterDelta, attackMode: attackMode,
            layer: layer, continuationKey: continuationKey,
            continuesFromPrevious: continuesFromPrevious, continuesIntoNext: continuesIntoNext,
            slide: slide
        )
    }
}

/// Compiles Chords (via PatternEventCompiler) + Bass + Melody into a single
/// sample-ordered CompiledPatternLoop with per-layer routing and continuation keys.
public enum MultiLayerEventCompiler {
    public static func compileWindow(
        progression: Progression,
        arrangement: PatternArrangement,
        bass: BassTrack = .empty,
        melody: MelodyTrack = .empty,
        mutedLayers: Set<MusicLayer> = [],
        tempo: Double,
        sampleRate: Double,
        loop: LoopSpan,
        cycleIndex: Int64 = 0,
        carryIn: Bool = false,
        carryOut: Bool = false
    ) throws -> CompiledPatternLoop {
        let (steps, overflow) = arrangement.barCount.multipliedReportingOverflow(by: MusicDefaults.stepsPerBar)
        guard !overflow, steps == progression.totalSteps else { throw PatternCompilerError.dimensionMismatch }

        let clock = try PatternEventCompiler.Clock(
            progression: progression, tempo: tempo, rate: sampleRate, loop: loop, cycle: cycleIndex
        )

        var harmonics: [PatternHarmonicRegion] = []
        var occurrences: [PatternOccurrence] = []
        var events: [PatternNoteEvent] = []

        if !mutedLayers.contains(.chords) {
            let compiled = try PatternEventCompiler.compile(
                progression,
                arrangement: arrangement,
                tempo: tempo,
                sampleRate: sampleRate,
                loop: loop,
                cycleIndex: cycleIndex,
                forcePerformance: true,
                carryIn: carryIn,
                carryOut: carryOut
            )
            if case .pattern(let chordLoop) = compiled {
                harmonics = chordLoop.harmonics
                occurrences = chordLoop.occurrences
                events = chordLoop.events
            }
        }

        var nextHarmonic = (harmonics.map(\.token.rawValue).max().map(Int.init) ?? 0) + 1
        var nextOccurrence = (occurrences.map(\.token.rawValue).max().map(Int.init) ?? 0) + 1
        var nextInstance = (events.map(\.instanceToken.rawValue).max().map(Int.init) ?? 0) + 1

        let windowStartTick = loop.start * MusicDefaults.ticksPerStep
        let windowEndTick = loop.end * MusicDefaults.ticksPerStep

        func appendTrackNotes(
            layer: MusicLayer,
            regionID: String,
            items: [(id: String, startTick: Int, endTick: Int, pitch: Int, velocity: Int, slide: Bool)]
        ) throws {
            let visible = items.filter { $0.endTick > windowStartTick && $0.startTick < windowEndTick }
            guard !visible.isEmpty else { return }

            let harmonicToken = PatternHarmonicToken(rawValue: try PatternEventCompiler.token(nextHarmonic))
            nextHarmonic += 1
            harmonics.append(PatternHarmonicRegion(token: harmonicToken, regionIndex: harmonics.count, regionID: regionID))

            for item in visible {
                let loTick = max(windowStartTick, item.startTick)
                let hiTick = min(windowEndTick, item.endTick)
                guard hiTick > loTick else { continue }

                let onStep = Double(loTick - windowStartTick) / Double(MusicDefaults.ticksPerStep)
                let offStep = Double(hiTick - windowStartTick) / Double(MusicDefaults.ticksPerStep)
                let onSample = try clock.offset(absolute: clock.absolute(step: onStep))
                let offSample = try clock.offset(absolute: clock.absolute(step: offStep))
                guard offSample > onSample else { continue }

                let occToken = PatternOccurrenceToken(rawValue: try PatternEventCompiler.token(nextOccurrence))
                nextOccurrence += 1
                let instToken = PatternNoteToken(rawValue: try PatternEventCompiler.token(nextInstance))
                nextInstance += 1

                let nominalStep = loTick / MusicDefaults.ticksPerStep
                let occ = PatternOccurrence(
                    token: occToken,
                    harmonicToken: harmonicToken,
                    nominalStep: nominalStep,
                    ownershipStartStep: loop.start,
                    ownershipEndStep: loop.end,
                    patternRegionID: nil,
                    strokeID: nil
                )
                occurrences.append(occ)

                let vel = Double(item.velocity) / 127.0
                let keyPrefix = layer == .bass ? "bass" : "melody"
                let contKey = "\(keyPrefix):\(item.id.utf8.count):\(item.id)"
                let fromPrev = carryIn && item.startTick < windowStartTick
                let intoNext = carryOut && item.endTick > windowEndTick

                let noteOn = PatternNoteEvent(
                    sampleOffset: onSample,
                    kind: .noteOn,
                    pitch: UInt8(item.pitch),
                    ascendingRank: 0,
                    onsetOrdinal: 0,
                    harmonicToken: harmonicToken,
                    occurrenceToken: occToken,
                    instanceToken: instToken,
                    baseVelocity: vel,
                    effectiveVelocity: vel,
                    timingJitterSeconds: 0,
                    detuneCents: 0,
                    filterDelta: 0,
                    attackMode: .ordinary,
                    layer: layer,
                    continuationKey: contKey,
                    continuesFromPrevious: fromPrev,
                    continuesIntoNext: intoNext,
                    slide: item.slide
                )
                events.append(noteOn)
                events.append(noteOn.ending(at: offSample))
            }
        }

        if !mutedLayers.contains(.bass) {
            try appendTrackNotes(
                layer: .bass,
                regionID: "__bass__",
                items: bass.notes.map { ($0.id, $0.startTick, $0.endTick, $0.pitch, $0.velocity, $0.slide) }
            )
        }

        if !mutedLayers.contains(.melody) {
            try appendTrackNotes(
                layer: .melody,
                regionID: "__melody__",
                items: melody.notes.map {
                    ($0.id, $0.effectiveStartTick, $0.effectiveEndTick, $0.pitch, $0.velocity, $0.slide)
                }
            )
        }

        events.sort { a, b in
            if a.sampleOffset != b.sampleOffset { return a.sampleOffset < b.sampleOffset }
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            if a.layer.nativeIndex != b.layer.nativeIndex { return a.layer.nativeIndex < b.layer.nativeIndex }
            if a.occurrenceToken != b.occurrenceToken { return a.occurrenceToken.rawValue < b.occurrenceToken.rawValue }
            if a.onsetOrdinal != b.onsetOrdinal { return a.onsetOrdinal < b.onsetOrdinal }
            return a.instanceToken.rawValue < b.instanceToken.rawValue
        }

        return CompiledPatternLoop(
            cycleIndex: cycleIndex,
            originSample: clock.origin,
            sampleCount: clock.count,
            looseAlgorithmVersion: PatternDefaults.looseAlgorithmVersion,
            harmonics: harmonics,
            occurrences: occurrences,
            events: events
        )
    }
}
