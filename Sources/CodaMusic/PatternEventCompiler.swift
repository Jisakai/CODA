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
                               cycleIndex: Int64 = 0) throws -> PatternCompilation {
        // This precondition deliberately precedes EVERY other error/delegation.
        let (steps, overflow) = arrangement.barCount.multipliedReportingOverflow(by: MusicDefaults.stepsPerBar)
        guard !overflow, steps == progression.totalSteps else { throw PatternCompilerError.dimensionMismatch }
        let coverage = arrangement.regions.filter {
            $0.range.start * MusicDefaults.stepsPerBar < loop.end &&
            $0.range.end * MusicDefaults.stepsPerBar > loop.start
        }
        guard !coverage.isEmpty else {
            return .legacy(try NoteEventCompiler.compile(progression, tempo: tempo,
                sampleRate: sampleRate, loop: loop, cycleIndex: cycleIndex))
        }
        let clock = try Clock(progression: progression, tempo: tempo, rate: sampleRate,
                              loop: loop, cycle: cycleIndex)
        guard progression.regions.allSatisfy({ $0.pitches.count <= PatternCompilerLimits.pitchesPerChord }) else {
            throw PatternCompilerError.pitchCapacity
        }
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
                let anchors = pattern == nil ? [lo] : Array(stride(from: ((lo + 1) / 2) * 2, to: hi, by: 2))
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
                    switch stroke?.content {
                    case .some(.chuck(_)):
                        mode = .chuck
                        ranks = Array(chord.pitches.indices)
                    case .some(.arrow(let direction, _)):
                        mode = .ordinary
                        ranks = direction == .down ? Array(chord.pitches.indices) : Array(chord.pitches.indices.reversed())
                    case .none:
                        mode = .ordinary
                        ranks = Array(chord.pitches.indices)
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
                        let pitch = chord.pitches[rank]
                        random.note(pitch)
                        let velocityRange = PatternDefaults.looseEffectiveVelocityRange
                        let velocity = loose ? min(velocityRange.upperBound, max(velocityRange.lowerBound,
                            base + random.value(channel: 1) * PatternDefaults.looseVelocityDelta)) : base
                        let detune = loose ? random.value(channel: 2) * PatternDefaults.looseDetuneCents : 0
                        let filter = loose ? random.value(channel: 3) * PatternDefaults.looseFilterDelta : 0
                        let gate = mode == .chuck ? try clock.offset(absolute:
                            min(hiTime, adjusted + PatternDefaults.chuckGateMilliseconds / 1000 * sampleRate)) : hiSample
                        let event = PatternNoteEvent(sampleOffset: on, kind: .noteOn, pitch: UInt8(pitch),
                            ascendingRank: rank, onsetOrdinal: ordinal, harmonicToken: harmonic,
                            occurrenceToken: occurrence.token, instanceToken: PatternNoteToken(rawValue: try token(attacks.count + 1)),
                            baseVelocity: base, effectiveVelocity: velocity, timingJitterSeconds: jitter,
                            detuneCents: detune, filterDelta: filter, attackMode: mode)
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
            let on = attack.event
            var off = min(attack.end, nextPitch[on.pitch] ?? clock.count)
            if let damp = dampings.first(where: { $0 > on.sampleOffset }) { off = min(off, damp) }
            guard off > on.sampleOffset else { throw MusicError.timingOverflow }
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

    private static func token(_ value: Int) throws -> UInt16 {
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

    private struct Clock {
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
        PatternNoteEvent(sampleOffset: sample, kind: .noteOff, pitch: pitch,
            ascendingRank: ascendingRank, onsetOrdinal: onsetOrdinal, harmonicToken: harmonicToken,
            occurrenceToken: occurrenceToken, instanceToken: instanceToken, baseVelocity: baseVelocity,
            effectiveVelocity: effectiveVelocity, timingJitterSeconds: timingJitterSeconds,
            detuneCents: detuneCents, filterDelta: filterDelta, attackMode: attackMode)
    }
}
