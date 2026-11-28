import Foundation
import CodaMusic
import CodaNative

/// Control-thread storage. The native transport synchronously copies this POD;
/// neither the pointer nor any Swift owner crosses into the render callback.
private final class PerformanceCycleStorage {
    let pointer = UnsafeMutablePointer<CodaPerformanceCycle>.allocate(capacity: 1)
    init() { pointer.initialize(to: CodaPerformanceCycle()) }
    deinit { pointer.deinitialize(count: 1); pointer.deallocate() }
}

final class NativePerformanceCycle {
    private let storage = PerformanceCycleStorage()
    var pointer: UnsafeMutablePointer<CodaPerformanceCycle> { storage.pointer }

    init(_ compiled: CompiledPatternLoop, continuations: [String: UInt64] = [:]) throws {
        guard let cycle = UInt64(exactly: compiled.cycleIndex), cycle < UInt64(Int64.max),
              let origin = UInt64(exactly: compiled.originSample),
              let count = UInt64(exactly: compiled.sampleCount), count > 0,
              let eventCount = UInt32(exactly: compiled.events.count),
              compiled.events.count <= Int(CODA_PLAN_EVENTS) else {
            throw AudioSessionError.invalidPlan
        }
        pointer.pointee.cycle_index = cycle
        pointer.pointee.sample_origin = origin
        pointer.pointee.sample_count = count
        pointer.pointee.count = eventCount
        try withUnsafeMutableBytes(of: &pointer.pointee.events) { raw in
            let events = raw.bindMemory(to: CodaPerformanceEvent.self)
            for (index, event) in compiled.events.enumerated() {
                guard event.sampleOffset >= 0, event.sampleOffset <= compiled.sampleCount,
                      let rank = UInt8(exactly: event.ascendingRank), rank < 12,
                      event.instanceToken.rawValue > 0, event.harmonicToken.rawValue > 0,
                      event.detuneCents.isFinite, event.filterDelta.isFinite else {
                    throw AudioSessionError.invalidPlan
                }
                var native = CodaPerformanceEvent()
                native.sample_offset = event.sampleOffset
                // Runtime epoch/generation/cycle/activation belong to native.
                native.owner.instance = UInt64(event.instanceToken.rawValue)
                native.harmonic_token = UInt64(event.harmonicToken.rawValue)
                native.kind = UInt8(event.kind.rawValue)
                native.pitch = event.pitch
                native.voice_rank = rank
                native.attack_mode = event.attackMode == .chuck ? 1 : 0
                native.base_velocity = try PerformancePlanBridge.preservePositiveVelocity(event.baseVelocity)
                native.effective_velocity = try PerformancePlanBridge.preservePositiveVelocity(event.effectiveVelocity)
                native.detune_cents = Float(event.detuneCents)
                native.filter_delta = Float(event.filterDelta)
                native.continuation_id = event.continuationKey.flatMap { continuations[$0] } ?? 0
                native.continuation_flags = (event.continuesFromPrevious ? 1 : 0) | (event.continuesIntoNext ? 2 : 0)
                native.slide = event.slide ? 1 : 0
                native.layer = event.layer.nativeIndex
                guard native.detune_cents.isFinite, native.filter_delta.isFinite else {
                    throw AudioSessionError.invalidPlan
                }
                events[index] = native
            }
        }
    }

    init(cycleIndex: Int64, originSample: Int64, sampleCount: Int64,
         events rawEvents: [CodaPerformanceEvent]) throws {
        guard let cycle = UInt64(exactly: cycleIndex), cycle < UInt64(Int64.max),
              let origin = UInt64(exactly: originSample),
              let count = UInt64(exactly: sampleCount), count > 0,
              let eventCount = UInt32(exactly: rawEvents.count),
              rawEvents.count <= Int(CODA_PLAN_EVENTS) else {
            throw AudioSessionError.invalidPlan
        }
        pointer.pointee.cycle_index = cycle
        pointer.pointee.sample_origin = origin
        pointer.pointee.sample_count = count
        pointer.pointee.count = eventCount
        withUnsafeMutableBytes(of: &pointer.pointee.events) { raw in
            let dst = raw.bindMemory(to: CodaPerformanceEvent.self)
            for (index, event) in rawEvents.enumerated() {
                dst[index] = event
            }
        }
    }
}

enum PerformancePlanBridge {
    /// Compiler velocities are Double; transport payloads are Float. Preserve
    /// ordinary Float quantization, but never turn a valid positive chuck into
    /// zero through underflow. Base and effective values convert independently.
    static func preservePositiveVelocity(_ value: Double) throws -> Float {
        guard value.isFinite, value > 0, value <= 1 else { throw AudioSessionError.invalidPlan }
        let converted = Float(value)
        return converted == 0 ? Float.leastNonzeroMagnitude : converted
    }
}

/// Immutable musical source plus a producer-owned refill cursor. One call does
/// at most one compilation/publication; full retains the identical POD for retry.
/// The session must acknowledge/promote generations separately before retiring
/// a source. This type never infers retirement from observational status fields.
@MainActor
final class PerformanceCycleSource {
    /// Capacity is per precompiled bar, never a limit on project duration.
    static let windowSteps = MusicDefaults.stepsPerBar
    let progression: Progression
    let arrangement: PatternArrangement
    let bassTrack: BassTrack
    let melodyTrack: MelodyTrack
    let extraLayers: [ExtraLayerTrack]
    let mutedLayers: Set<MusicLayer>
    let tempo: Double
    let sampleRate: Double
    let span: LoopSpan
    private(set) var nextCycle: Int64
    private(set) var retainedCycle: NativePerformanceCycle?
    private var continuationIDs: [String: UInt64] = [:]
    private var nextContinuation: UInt64 = 1

    init(progression: Progression, arrangement: PatternArrangement,
         bassTrack: BassTrack = .empty, melodyTrack: MelodyTrack = .empty,
         extraLayers: [ExtraLayerTrack] = [],
         mutedLayers: Set<MusicLayer> = [],
         tempo: Double, sampleRate: Double, span: LoopSpan, initialCycle: Int64) throws {
        guard initialCycle >= 0, initialCycle < Int64.max else { throw AudioSessionError.capacity }
        self.progression = progression
        self.arrangement = arrangement
        self.bassTrack = bassTrack
        self.melodyTrack = melodyTrack
        self.extraLayers = extraLayers
        self.mutedLayers = mutedLayers
        self.tempo = tempo
        self.sampleRate = sampleRate
        self.span = span
        nextCycle = initialCycle + 1
    }

    func compile(cycle: Int64) throws -> NativePerformanceCycle {
        guard cycle >= 0 else { throw AudioSessionError.invalidPlan }
        let windows = span.length / Self.windowSteps
        let index = Int(cycle % Int64(windows))
        let start = span.start + index * Self.windowSteps
        let window = try LoopSpan(start: start, bars: 1)
        let compiled: CompiledPatternLoop
        let activeExtra = extraLayers.filter { !$0.muted && !$0.notes.isEmpty }
        if bassTrack.notes.isEmpty && melodyTrack.notes.isEmpty && mutedLayers.isEmpty && activeExtra.isEmpty {
            switch try PatternEventCompiler.compile(progression, arrangement: arrangement,
                tempo: tempo, sampleRate: sampleRate, loop: window, cycleIndex: cycle,
                forcePerformance: true, carryIn: index > 0, carryOut: index + 1 < windows) {
            case .legacy: throw AudioSessionError.invalidPlan // caller must keep the exact legacy branch
            case .pattern(let loop): compiled = loop
            }
        } else {
            compiled = try MultiLayerEventCompiler.compileWindow(
                progression: progression,
                arrangement: arrangement,
                bass: bassTrack,
                melody: melodyTrack,
                mutedLayers: mutedLayers,
                tempo: tempo,
                sampleRate: sampleRate,
                loop: window,
                cycleIndex: cycle,
                carryIn: index > 0,
                carryOut: index + 1 < windows
            )
        }
        // Only current/next windows need a key registry. Keep identities for
        // surviving sustain keys, retire finished notes, and never wrap IDs.
        let keys = Set(compiled.events.compactMap(\.continuationKey))
        continuationIDs = continuationIDs.filter { keys.contains($0.key) }
        for key in keys.sorted() where continuationIDs[key] == nil {
            guard nextContinuation < UInt64.max else { throw AudioSessionError.capacity }
            continuationIDs[key] = nextContinuation; nextContinuation += 1
        }
        if activeExtra.isEmpty {
            return try NativePerformanceCycle(compiled, continuations: continuationIDs)
        }
        // Merge primary events with extra overlay track events (DSP slots 3..<12).
        var merged: [CodaPerformanceEvent] = []
        merged.reserveCapacity(compiled.events.count + activeExtra.count * 32)
        for event in compiled.events {
            guard event.sampleOffset >= 0, event.sampleOffset <= compiled.sampleCount,
                  let rank = UInt8(exactly: event.ascendingRank), rank < 12,
                  event.instanceToken.rawValue > 0, event.harmonicToken.rawValue > 0,
                  event.detuneCents.isFinite, event.filterDelta.isFinite else {
                throw AudioSessionError.invalidPlan
            }
            var native = CodaPerformanceEvent()
            native.sample_offset = event.sampleOffset
            native.owner.instance = UInt64(event.instanceToken.rawValue)
            native.harmonic_token = UInt64(event.harmonicToken.rawValue)
            native.kind = UInt8(event.kind.rawValue)
            native.pitch = event.pitch
            native.voice_rank = rank
            native.attack_mode = event.attackMode == .chuck ? 1 : 0
            native.base_velocity = try PerformancePlanBridge.preservePositiveVelocity(event.baseVelocity)
            native.effective_velocity = try PerformancePlanBridge.preservePositiveVelocity(event.effectiveVelocity)
            native.detune_cents = Float(event.detuneCents)
            native.filter_delta = Float(event.filterDelta)
            native.continuation_id = event.continuationKey.flatMap { continuationIDs[$0] } ?? 0
            native.continuation_flags = (event.continuesFromPrevious ? 1 : 0) | (event.continuesIntoNext ? 2 : 0)
            native.slide = event.slide ? 1 : 0
            native.layer = event.layer.nativeIndex
            merged.append(native)
        }
        let samplesPerTick = sampleRate * 60.0 / tempo / Double(MusicDefaults.ticksPerBeat)
        let windowStartTick = window.start * MusicDefaults.ticksPerStep
        let windowEndTick = window.end * MusicDefaults.ticksPerStep
        var nextExtraInstance: UInt64 = 10_000_000
        for track in activeExtra {
            guard track.dspSlot >= Int(CODA_LAYER_COUNT.rawValue), track.dspSlot < Int(CODA_MAX_TRACKS) else { continue }
            for note in track.notes {
                guard note.endTick > windowStartTick, note.startTick < windowEndTick else { continue }
                let clippedStart = max(note.startTick, windowStartTick) - windowStartTick
                let clippedEnd = min(note.endTick, windowEndTick) - windowStartTick
                let onSample = Int64(floor(Double(clippedStart) * samplesPerTick))
                let offSample = min(compiled.sampleCount, max(onSample + 1, Int64(ceil(Double(clippedEnd) * samplesPerTick))))
                guard onSample >= 0, onSample < compiled.sampleCount, offSample <= compiled.sampleCount else { continue }
                let vel = try PerformancePlanBridge.preservePositiveVelocity(max(0.05, min(1.0, Double(note.velocity) / 127.0)))
                let inst = nextExtraInstance; nextExtraInstance += 1
                var onEv = CodaPerformanceEvent()
                onEv.sample_offset = onSample
                onEv.owner.instance = inst
                onEv.harmonic_token = UInt64(track.dspSlot + 1)
                onEv.kind = UInt8(CODA_EVENT_ON.rawValue)
                onEv.pitch = UInt8(clamping: note.pitch)
                onEv.voice_rank = 0
                onEv.attack_mode = 0
                onEv.base_velocity = vel
                onEv.effective_velocity = vel
                onEv.slide = note.slide ? 1 : 0
                onEv.layer = UInt8(track.dspSlot)
                var offEv = onEv
                offEv.sample_offset = offSample
                offEv.kind = UInt8(CODA_EVENT_OFF.rawValue)
                merged.append(onEv)
                merged.append(offEv)
            }
        }
        merged.sort { a, b in
            if a.sample_offset != b.sample_offset { return a.sample_offset < b.sample_offset }
            if a.kind != b.kind { return a.kind < b.kind }
            if a.layer != b.layer { return a.layer < b.layer }
            if a.pitch != b.pitch { return a.pitch < b.pitch }
            return a.owner.instance < b.owner.instance
        }
        return try NativePerformanceCycle(
            cycleIndex: compiled.cycleIndex,
            originSample: compiled.originSample,
            sampleCount: compiled.sampleCount,
            events: merged
        )
    }

    /// Limit lookahead to current + next two. Never reconstruct cycle zero.
    @discardableResult
    func refill(audio: CodaAudioAdapter, generation: UInt64, currentCycle: UInt64) throws -> Int32 {
        guard generation > 0, currentCycle <= UInt64(Int64.max), nextCycle < Int64.max else {
            throw AudioSessionError.capacity
        }
        // Observations can mix generations. Only native admission decides whether
        // the exact consecutive payload is still needed; never skip a cycle.
        if UInt64(nextCycle) > currentCycle, UInt64(nextCycle) - currentCycle > 2 { return 0 }
        if retainedCycle == nil { retainedCycle = try compile(cycle: nextCycle) }
        guard let retainedCycle else { throw AudioSessionError.invalidPlan }
        let result = audio.enqueue(performanceCycle: retainedCycle.pointer, generation: generation)
        if result == 1 { nextCycle += 1; self.retainedCycle = nil }
        // -1 is deliberately returned: only the session's explicit replacement
        // acknowledgement/lifecycle can prove retirement rather than failure.
        return result
    }
}

final class NativePerformancePlan {
    let pointer = UnsafeMutablePointer<CodaPerformancePlan>.allocate(capacity: 1)
    init() { pointer.initialize(to: CodaPerformancePlan()) }
    deinit { pointer.deinitialize(count: 1); pointer.deallocate() }
}
