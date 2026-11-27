import Foundation
import XCTest
import CodaMusic
import CodaNative
@testable import CodaSession

final class PerformancePlanBridgeTests: XCTestCase {
    @MainActor
    func testRealRefillBackpressureRetainsExactPayloadAndCursor() throws {
        let vocabulary = try ChordVocabulary.load(in: Bundle(for: Self.self))
        var editor = ProgressionEditor(try Progression(vocabulary: vocabulary))
        try editor.apply([.add(ChordRegion(id: "full-chord", chord: Chord(root: 0, qualityID: "minor7"),
            start: 0, length: 16, pitches: [60, 63, 67, 70]))], vocabulary: vocabulary,
            solver: VoiceLeadingSolver())
        let region = try PatternPreset.popRock.instantiate(id: "full-pattern",
            range: PatternBarRange(start: 0, length: 1),
            occupiedStrokeIDs: (0..<6).map { "full-\($0)" },
            settings: PatternSettings(humanize: .loose))
        let audio = CodaAudioAdapter()
        try audio.open(offline: true)
        defer { audio.close() }
        let source = try PerformanceCycleSource(progression: editor.progression,
            arrangement: PatternArrangement(regions: [region]), tempo: 120,
            sampleRate: audio.sampleRate, span: LoopSpan(bars: 1), initialCycle: 0)
        let plan = NativePerformancePlan()
        plan.pointer.pointee.samples_per_step = audio.sampleRate / 8
        plan.pointer.pointee.length = 16
        plan.pointer.pointee.playback_revision = 1
        plan.pointer.pointee.playing = 1
        plan.pointer.pointee.looping = 1
        plan.pointer.pointee.initial_cycle = try source.compile(cycle: 0).pointer.pointee
        var generation: UInt64 = 0
        XCTAssertEqual(audio.publish(performancePlan: plan.pointer, generation: &generation), 1)
        for _ in 0..<3 {
            XCTAssertEqual(try source.refill(audio: audio, generation: generation, currentCycle: 10), 1)
        }
        XCTAssertEqual(source.nextCycle, 4)
        XCTAssertEqual(try source.refill(audio: audio, generation: generation, currentCycle: 10), 0)
        let retained = try XCTUnwrap(source.retainedCycle)
        XCTAssertEqual(retained.pointer.pointee.cycle_index, 4)
        XCTAssertEqual(try source.refill(audio: audio, generation: generation, currentCycle: 10), 0)
        XCTAssertTrue(source.retainedCycle === retained)
        XCTAssertEqual(source.nextCycle, 4)
        try audio.start()
        var energy = 0.0
        // Releasing the consumed lane slot requires entering cycle two.
        try audio.renderOffline(frames: 192_001, energy: &energy)
        XCTAssertEqual(audio.performanceStatus().cycle, 2)
        XCTAssertEqual(try source.refill(audio: audio, generation: generation, currentCycle: 2), 1)
        XCTAssertEqual(source.nextCycle, 5)
        XCTAssertNil(source.retainedCycle)
        XCTAssertEqual(audio.transportStatus().failures, 0)
        XCTAssertEqual(audio.performanceStatus().underruns, 0)
    }

    func testPositiveVelocityPolicyAndIndependentFloatQuantization() throws {
        for level in 1...10 {
            let value = try ArrowLevel(level).baseVelocity
            XCTAssertEqual(try PerformancePlanBridge.preservePositiveVelocity(value), Float(value))
        }
        XCTAssertEqual(try PerformancePlanBridge.preservePositiveVelocity(Double.leastNonzeroMagnitude),
                       Float.leastNonzeroMagnitude)
        for value in [0.0, -0.1, 1.01, .infinity, .nan] {
            XCTAssertThrowsError(try PerformancePlanBridge.preservePositiveVelocity(value))
        }
    }

    func testCompilerAcceptedTinyChuckSurvivesBridgeInTightAndLoose() throws {
        let vocabulary = try ChordVocabulary.load(in: Bundle(for: Self.self))
        var editor = ProgressionEditor(try Progression(vocabulary: vocabulary))
        try editor.apply([.add(ChordRegion(id: "tiny-chord", chord: Chord(root: 0, qualityID: "minor7"),
            start: 0, length: 16, pitches: [60, 63, 67, 70]))], vocabulary: vocabulary,
            solver: VoiceLeadingSolver())
        for humanize in [PatternHumanize.tight, .loose] {
            let stroke = try PatternStroke(id: "tiny-chuck", content: .chuck(ChuckSize(Double.leastNonzeroMagnitude)))
            let region = try PatternRegion(id: "tiny-pattern", range: PatternBarRange(start: 0, length: 1),
                slots: [stroke, nil, nil, nil, nil, nil, nil, nil],
                settings: PatternSettings(humanize: humanize))
            guard case .pattern(let compiled) = try PatternEventCompiler.compile(editor.progression,
                arrangement: PatternArrangement(regions: [region]), tempo: 137.3,
                sampleRate: 48000, loop: LoopSpan(bars: 1)) else { return XCTFail("Expected tiny chuck") }
            let native = try NativePerformanceCycle(compiled)
            XCTAssertFalse(compiled.events.isEmpty)
            try withUnsafeBytes(of: &native.pointer.pointee.events) { raw in
                let events = raw.bindMemory(to: CodaPerformanceEvent.self)
                for (index, event) in compiled.events.enumerated() {
                    XCTAssertEqual(events[index].base_velocity, Float.leastNonzeroMagnitude)
                    XCTAssertEqual(events[index].effective_velocity,
                        try PerformancePlanBridge.preservePositiveVelocity(event.effectiveVelocity))
                    XCTAssertEqual(events[index].attack_mode, 1)
                    if humanize == .tight {
                        XCTAssertEqual(events[index].base_velocity, events[index].effective_velocity)
                    } else {
                        XCTAssertGreaterThan(events[index].effective_velocity, events[index].base_velocity)
                    }
                }
            }
        }
    }

    @MainActor
    func testActualCompilerPayloadsAndSeparatelyCompiledCyclesThroughOfflineAdapter() throws {
        let vocabulary = try ChordVocabulary.load(in: Bundle(for: Self.self))
        var editor = ProgressionEditor(try Progression(vocabulary: vocabulary))
        try editor.apply([.add(ChordRegion(id: "bridge-chord", chord: Chord(root: 0, qualityID: "minor7"),
            start: 0, length: 16, pitches: [60, 63, 67, 70]))], vocabulary: vocabulary,
            solver: VoiceLeadingSolver())
        let region = try PatternPreset.popRock.instantiate(id: "bridge-pattern",
            range: PatternBarRange(start: 0, length: 1),
            occupiedStrokeIDs: (0..<6).map { "stroke-\($0)" },
            settings: PatternSettings(swing: 0.4, humanize: .loose, spreadMilliseconds: 43))
        let arrangement = try PatternArrangement(regions: [region])
        let span = try LoopSpan(bars: 1)
        let audio = CodaAudioAdapter()
        try audio.open(offline: true)
        defer { audio.close() }
        let source = try PerformanceCycleSource(progression: editor.progression, arrangement: arrangement,
            tempo: 137.3, sampleRate: audio.sampleRate, span: span, initialCycle: 0)
        var previousEvents: [PatternNoteEvent] = []
        for index in Int64(0)...Int64(2) {
            guard case .pattern(let compiled) = try PatternEventCompiler.compile(editor.progression,
                arrangement: arrangement, tempo: 137.3, sampleRate: audio.sampleRate,
                loop: span, cycleIndex: index) else { return XCTFail("Expected real pattern") }
            let native = try source.compile(cycle: index)
            XCTAssertEqual(native.pointer.pointee.cycle_index, UInt64(index))
            XCTAssertEqual(native.pointer.pointee.sample_origin, UInt64(compiled.originSample))
            XCTAssertEqual(native.pointer.pointee.sample_count, UInt64(compiled.sampleCount))
            XCTAssertEqual(native.pointer.pointee.count, UInt32(compiled.events.count))
            withUnsafeBytes(of: &native.pointer.pointee.events) { raw in
                let values = raw.bindMemory(to: CodaPerformanceEvent.self)
                for (i, event) in compiled.events.enumerated() {
                    let value = values[i]
                    XCTAssertEqual(value.sample_offset, event.sampleOffset)
                    XCTAssertEqual(value.owner.instance, UInt64(event.instanceToken.rawValue))
                    XCTAssertEqual(value.owner.prepare_epoch, 0)
                    XCTAssertEqual(value.owner.plan_generation, 0)
                    XCTAssertEqual(value.owner.cycle, 0)
                    XCTAssertEqual(value.owner.activation, 0)
                    XCTAssertEqual(value.harmonic_token, UInt64(event.harmonicToken.rawValue))
                    XCTAssertEqual(value.kind, UInt8(event.kind.rawValue))
                    XCTAssertEqual(value.pitch, event.pitch)
                    XCTAssertEqual(value.voice_rank, UInt8(event.ascendingRank))
                    XCTAssertEqual(value.base_velocity, Float(event.baseVelocity))
                    XCTAssertEqual(value.effective_velocity, Float(event.effectiveVelocity))
                    XCTAssertEqual(value.detune_cents, Float(event.detuneCents))
                    XCTAssertEqual(value.filter_delta, Float(event.filterDelta))
                    XCTAssertEqual(value.attack_mode, event.attackMode == .chuck ? 1 : 0)
                }
            }
            if index > 0 { XCTAssertNotEqual(previousEvents, compiled.events) }
            previousEvents = compiled.events
        }
        // Heap-owned plan, as in production; never put the 3072-event POD on a Swift stack.
        let plan = UnsafeMutablePointer<CodaPerformancePlan>.allocate(capacity: 1)
        plan.initialize(to: CodaPerformancePlan())
        defer { plan.deinitialize(count: 1); plan.deallocate() }
        plan.pointee.samples_per_step = audio.sampleRate * 60 / 137.3 / 4
        plan.pointee.length = 16
        plan.pointee.playback_revision = 1
        plan.pointee.playing = 1
        plan.pointee.looping = 1
        plan.pointee.initial_cycle = try source.compile(cycle: 0).pointer.pointee
        var generation: UInt64 = 0
        XCTAssertEqual(audio.publish(performancePlan: plan, generation: &generation), 1)
        XCTAssertGreaterThan(generation, 0)
        // Deliberately exhaust the initial cycle without producer lookahead.
        // Recover using the exact missing request, including current == next.
        try audio.start()
        for _ in 0..<1000 {
            if audio.performanceStatus().underrun != 0 { break }
            var energy = 0.0
            try audio.renderOffline(frames: 4096, energy: &energy)
        }
        let starved = audio.performanceStatus()
        XCTAssertNotEqual(starved.underrun, 0)
        XCTAssertEqual(starved.next_requested_cycle, 1)
        XCTAssertEqual(source.nextCycle, 1)
        XCTAssertEqual(try source.refill(audio: audio, generation: generation,
            currentCycle: starved.next_requested_cycle), 1)
        var recoveryEnergy = 0.0
        try audio.renderOffline(frames: 4096, energy: &recoveryEnergy)
        XCTAssertEqual(audio.performanceStatus().underrun, 0)
        XCTAssertEqual(audio.performanceStatus().cycle, 1)
        XCTAssertGreaterThan(recoveryEnergy, 0)
        XCTAssertEqual(try source.refill(audio: audio, generation: generation, currentCycle: 0), 1)
        XCTAssertEqual(source.nextCycle, 3)
        XCTAssertEqual(try source.refill(audio: audio, generation: generation, currentCycle: 0), 0)
        var totalEnergy = 0.0
        while audio.performanceStatus().cycle < 6 {
            let cycle = audio.performanceStatus().cycle
            _ = try source.refill(audio: audio, generation: generation, currentCycle: cycle)
            var energy = 0.0
            try audio.renderOffline(frames: 4096, energy: &energy)
            totalEnergy += energy
            XCTAssertEqual(audio.transportStatus().failures, 0)
            // A failing engine must fail the test instead of looping indefinitely.
            if audio.transportStatus().clock > 2_000_000 { return XCTFail("Cycle refill stalled") }
        }
        XCTAssertGreaterThan(totalEnergy, 0)
        XCTAssertEqual(audio.performanceStatus().applied_generation, generation)
        XCTAssertEqual(audio.performanceStatus().underruns, 1)
    }
}
