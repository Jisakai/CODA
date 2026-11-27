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

    init(_ compiled: CompiledPatternLoop) throws {
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
                guard native.detune_cents.isFinite, native.filter_delta.isFinite else {
                    throw AudioSessionError.invalidPlan
                }
                events[index] = native
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
    let progression: Progression
    let arrangement: PatternArrangement
    let tempo: Double
    let sampleRate: Double
    let span: LoopSpan
    private(set) var nextCycle: Int64
    private(set) var retainedCycle: NativePerformanceCycle?

    init(progression: Progression, arrangement: PatternArrangement, tempo: Double,
         sampleRate: Double, span: LoopSpan, initialCycle: Int64) throws {
        guard initialCycle >= 0, initialCycle < Int64.max else { throw AudioSessionError.capacity }
        self.progression = progression; self.arrangement = arrangement
        self.tempo = tempo; self.sampleRate = sampleRate; self.span = span
        nextCycle = initialCycle + 1
    }

    func compile(cycle: Int64) throws -> NativePerformanceCycle {
        switch try PatternEventCompiler.compile(progression, arrangement: arrangement,
            tempo: tempo, sampleRate: sampleRate, loop: span, cycleIndex: cycle) {
        case .legacy: throw AudioSessionError.invalidPlan // caller must keep the exact legacy branch
        case .pattern(let compiled): return try NativePerformanceCycle(compiled)
        }
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
