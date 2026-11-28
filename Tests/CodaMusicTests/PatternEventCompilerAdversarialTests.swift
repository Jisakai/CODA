import Foundation
import XCTest
@testable import CodaMusic

final class PatternEventCompilerAdversarialTests: PatternCompilerTestCase {
    func testChuckDampsAtFirstRetainedOnsetAfterOrdinaryCollisionWinners() throws {
        let p = try progression(bars: 1)
        // 100Hz/6000BPM: chuck candidates round to [1,1,1,2]. The later
        // ordinary block wins all three sample1 collisions; only pitch70 at2
        // remains a chuck. Damping must occur at2, not the discarded sample1.
        let c = try compile(p, [pattern([0: arrow(2), 1: .chuck(ChuckSize(0.317)),
            2: arrow(9)], settings: PatternSettings(spreadMilliseconds: 0))], tempo: 6000, rate: 100)
        let chuck = ons(c).filter { $0.attackMode == .chuck }
        XCTAssertEqual(chuck.map(\.sampleOffset), [2])
        XCTAssertEqual(chuck.map(\.pitch), [70])
        XCTAssertEqual(chuck.first?.baseVelocity, 0.317)
        let ordinary = ons(c).filter { $0.baseVelocity == 0.9 }
        XCTAssertEqual(ordinary.count, 4)
        XCTAssertTrue(ordinary.allSatisfy { $0.sampleOffset == 1 })
        for on in ordinary {
            XCTAssertEqual(offs(c).filter { $0.instanceToken == on.instanceToken }.map(\.sampleOffset), [2])
        }
        XCTAssertEqual(replay(c, through: 1).count, 4)
        XCTAssertEqual(replay(c, through: 2).count, 1)
        replay(c)
    }

    func testFullyCoalescedChuckHasNoDampingOrCollapsedGateRejection() throws {
        let p = try progression(bars: 1)
        // At2Hz chuck candidates and their gates all round to1, as does the
        // later ordinary block. Discarded chucks cannot fail lifetime checks.
        let c = try compile(p, [pattern([0: arrow(2), 1: .chuck(ChuckSize(0.317)),
            2: arrow(9)], settings: PatternSettings(spreadMilliseconds: 0))], rate: 2)
        XCTAssertEqual(c.sampleCount, 4)
        XCTAssertEqual(ons(c).count, 8)
        XCTAssertTrue(ons(c).allSatisfy { $0.attackMode == .ordinary })
        XCTAssertTrue(offs(c).filter { $0.baseVelocity == 0.9 }.allSatisfy { $0.sampleOffset == 4 })
        XCTAssertEqual(replay(c, through: 2).count, 4)
        replay(c)
    }

    func testOppositeDirectionsSwingSpreadCollisionKeepsLatestNominalAndHasNoStaleOffs() throws {
        let p = try progression(bars: 1)
        // 750 BPM -> 20ms/sixteenth. Down's last note and swung up's
        // first note both land at60ms. Coalesce BEFORE deriving note offs.
        let c = try compile(p, [pattern([0: arrow(2), 1: arrow(9, .up)],
            settings: PatternSettings(swing: 1, spreadMilliseconds: 60))], tempo: 750)
        let attacks = ons(c)
        XCTAssertEqual(attacks.count, 7)
        let high = attacks.filter { $0.pitch == 70 }
        XCTAssertEqual(high.count, 1)
        let winner = try XCTUnwrap(high.first)
        XCTAssertEqual(winner.sampleOffset, 2_880)
        XCTAssertEqual(winner.baseVelocity, 0.9)
        XCTAssertEqual(winner.occurrenceToken, c.occurrences[1].token)
        XCTAssertEqual(winner.onsetOrdinal, 0)
        XCTAssertEqual(winner.ascendingRank, 3)
        XCTAssertEqual(attacks.map(\.sampleOffset), [0, 960, 1920, 2880, 3840, 4800, 5760])
        XCTAssertEqual(Set(attacks.map(\.instanceToken)).count, 7)
        for on in attacks {
            let matching = offs(c).filter { $0.instanceToken == on.instanceToken }
            XCTAssertEqual(matching.count, 1)
            let off = try XCTUnwrap(matching.first)
            let next = attacks.first { $0.pitch == on.pitch && $0.sampleOffset > on.sampleOffset }
            XCTAssertEqual(off.sampleOffset, next?.sampleOffset ?? c.sampleCount)
        }
        for sample in [Int64(2_880), 3_840, 4_800, 5_760] {
            XCTAssertEqual(replay(c, through: sample).count, 4)
        }
        for group in Dictionary(grouping: c.events, by: \.sampleOffset).values {
            let kinds = group.map { $0.kind.rawValue }
            XCTAssertEqual(kinds, kinds.sorted(), "Exact-instance offs must precede replacement ons")
        }
        replay(c)
    }

    func testRoundedCollisionsCoalesceBeforeNonpositiveLifetimeAndCapacityChecks() throws {
        let pitches = [0, 3, 7, 10, 12, 15, 19, 22, 24, 27, 31, 34]
        let p = try progression([region(length: 16, pitches: pitches)], bars: 1)
        let contents = try Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, try arrow($0 + 1)) })
        // One step = 0.25 samples. Adjacent slots collapse onto common samples;
        // superseded instances must vanish with their offs, not throw.
        let c = try compile(p, [pattern(contents, settings: PatternSettings(spreadMilliseconds: 0))], rate: 2)
        XCTAssertEqual(c.sampleCount, 4)
        XCTAssertEqual(ons(c).count, 4 * 12)
        XCTAssertEqual(c.events.count, 96)
        for sample in Int64(0)..<4 {
            let group = ons(c).filter { $0.sampleOffset == sample }
            XCTAssertEqual(group.count, 12)
            let expectedSlot = sample == 0 ? 0 : Int(sample * 2)
            XCTAssertTrue(group.allSatisfy { $0.baseVelocity == Double(expectedSlot + 1) / 10 })
        }
        replay(c)
    }

    func testChuckInterruptsUnfinishedSpreadCancelsPendingOlderNotesAndDampsOnce() throws {
        let p = try progression(bars: 1)
        let c = try compile(p, [pattern([0: arrow(), 1: .chuck(ChuckSize(0.317))],
            settings: PatternSettings(spreadMilliseconds: 60))], tempo: 3000)
        let ordinary = ons(c).filter { $0.attackMode == .ordinary }
        let chuck = ons(c).filter { $0.attackMode == .chuck }
        XCTAssertEqual(ordinary.map(\.pitch), [60], "Pending old spread notes at/after damping must never sound")
        XCTAssertEqual(chuck.map(\.pitch), [60, 63, 67, 70])
        XCTAssertEqual(chuck.map(\.sampleOffset), [480, 672, 864, 1056])
        XCTAssertEqual(chuck.map(\.onsetOrdinal), [0, 1, 2, 3])
        XCTAssertEqual(chuck.map(\.ascendingRank), [0, 1, 2, 3])
        let damped = try XCTUnwrap(ordinary.first)
        XCTAssertEqual(offs(c).filter { $0.instanceToken == damped.instanceToken }.map(\.sampleOffset), [480])
        XCTAssertEqual(c.events.filter { $0.sampleOffset == 480 }.map(\.kind), [.noteOff, .noteOn])
        for on in chuck {
            XCTAssertEqual(on.baseVelocity, 0.317)
            XCTAssertEqual(on.effectiveVelocity, 0.317)
            let off = try XCTUnwrap(offs(c).first { $0.instanceToken == on.instanceToken })
            XCTAssertEqual(off.sampleOffset - on.sampleOffset, 1920, "40ms gate starts at EACH adjusted rake onset")
        }
        XCTAssertEqual(replay(c, through: 1_500).count, 4)
        XCTAssertEqual(replay(c, through: 2_500).count, 3)
        XCTAssertEqual(replay(c, through: 3_000).count, 0)
        replay(c)
    }

    func testChuckPendingOnsetExactlyAtDampingAndSubsequentChuckGateClip() throws {
        let p = try progression(bars: 1)
        // 1500BPM ->20ms/eighth. Prior spread note1 is EXACTLY the
        // chuck damping sample; it must be cancelled, not emitted/released.
        let c = try compile(p, [pattern([0: arrow(), 1: .chuck(ChuckSize(0.4)),
            2: .chuck(ChuckSize(0.6))], settings: PatternSettings(spreadMilliseconds: 60))], tempo: 1500)
        XCTAssertEqual(ons(c).filter { $0.attackMode == .ordinary }.map(\.sampleOffset), [0])
        let firstToken = c.occurrences[1].token
        let secondToken = c.occurrences[2].token
        XCTAssertEqual(ons(c).filter { $0.occurrenceToken == firstToken }.count, 4)
        XCTAssertTrue(offs(c).filter { $0.occurrenceToken == firstToken }.allSatisfy { $0.sampleOffset == 1920 })
        XCTAssertEqual(ons(c).filter { $0.occurrenceToken == secondToken }.map(\.sampleOffset), [1920, 2112, 2304, 2496])
        replay(c)
    }

    func testNewChuckCancelsUnfinishedOlderChuckAndClippedChuckDoesNotDamp() throws {
        let p = try progression(bars: 1)
        let c = try compile(p, [pattern([0: .chuck(ChuckSize(0.3)), 1: .chuck(ChuckSize(0.7))])], tempo: 6000)
        // Eighth5ms, old chuck rake12ms: old notes at8/12ms cancelled.
        XCTAssertEqual(ons(c).filter { $0.baseVelocity == 0.3 }.map(\.sampleOffset), [0, 192])
        XCTAssertTrue(offs(c).filter { $0.baseVelocity == 0.3 }.allSatisfy { $0.sampleOffset == 240 })
        XCTAssertEqual(ons(c).filter { $0.baseVelocity == 0.7 }.count, 4)
        replay(c)

        let short = try progression([region(length: 3)], bars: 1)
        let clipped = try compile(short, [pattern([0: arrow(), 1: .chuck(ChuckSize(0.3))],
            settings: PatternSettings(swing: 1, spreadMilliseconds: 0))])
        XCTAssertEqual(ons(clipped).count, 4)
        XCTAssertTrue(ons(clipped).allSatisfy { $0.attackMode == .ordinary })
        XCTAssertTrue(offs(clipped).allSatisfy { $0.sampleOffset == 18_000 })
        replay(clipped)

        let partial = try compile(short, [pattern([1: .chuck(ChuckSize(0.3))])], tempo: 3000)
        XCTAssertEqual(ons(partial).map(\.sampleOffset), [480, 672])
        XCTAssertEqual(offs(partial).map(\.sampleOffset), [720, 720])
        replay(partial)
    }

    func testChuckTightContinuousTinyPositiveVelocityAndPerNoteAdjustedGate() throws {
        let p = try progression(bars: 1)
        for size in [Double.leastNonzeroMagnitude, 0.317, 1] {
            let c = try compile(p, [pattern([1: .chuck(ChuckSize(size))],
                settings: PatternSettings(swing: 0.5, spreadMilliseconds: 60))])
            let attacks = ons(c)
            XCTAssertEqual(attacks.map(\.sampleOffset), [15000, 15192, 15384, 15576])
            let first = try XCTUnwrap(attacks.first)
            let last = try XCTUnwrap(attacks.last)
            XCTAssertEqual(last.sampleOffset - first.sampleOffset, 576, "12ms TOTAL, independent of ordinary spread60")
            for event in attacks {
                XCTAssertEqual(event.baseVelocity, size)
                XCTAssertEqual(event.effectiveVelocity, size, "Tight must not apply Loose's minimum clamp")
                XCTAssertEqual(event.timingJitterSeconds, 0)
                XCTAssertEqual(event.detuneCents, 0)
                XCTAssertEqual(event.filterDelta, 0)
                let off = try XCTUnwrap(offs(c).first { $0.instanceToken == event.instanceToken })
                XCTAssertEqual(off.sampleOffset - event.sampleOffset, 1920)
            }
            replay(c)
        }
    }

    func testSwingOnlyOddEighthsAndLateOnsetsRespectPatternLoopChordBoundaries() throws {
        let p = try progression(bars: 2)
        let contents = try Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, try arrow()) })
        for swing in [0.0, 0.5, 1] {
            let c = try compile(p, [pattern(contents, bars: 2,
                settings: PatternSettings(swing: swing, spreadMilliseconds: 0))])
            for on in ons(c) {
                let occurrence = try XCTUnwrap(c.occurrences.first { $0.token == on.occurrenceToken })
                let step = occurrence.nominalStep
                let delay = (step / 2).isMultiple(of: 2) ? 0 : swing * 6000
                XCTAssertEqual(on.sampleOffset, Int64(Double(step * 6000) + delay))
                XCTAssertLessThan(on.sampleOffset, Int64(occurrence.ownershipEndStep * 6000))
            }
            replay(c)
        }
        let fast = try compile(p, [pattern([7: arrow()], settings: PatternSettings(swing: 1, spreadMilliseconds: 60))],
            tempo: 3000, loop: LoopSpan(bars: 1))
        XCTAssertEqual(ons(fast).count, 1, "Late spread may not leak through the pattern/loop boundary")
        XCTAssertEqual(ons(fast).first?.sampleOffset, 3600)
        XCTAssertEqual(offs(fast).first?.sampleOffset, 3840)
        replay(fast)
    }

    func testLooseDeterministicVersionedStableIdentityBoundsSharedJitterAndVariation() throws {
        let p = try progression(bars: 2)
        let settings = try PatternSettings(swing: 0.37, humanize: .loose, spreadMilliseconds: 20, looseSeed: 0xfeedbeef)
        let pat = try pattern([0: arrow(), 1: arrow(), 3: .chuck(ChuckSize(0.317)), 6: arrow(8, .up)], bars: 2, settings: settings)
        var cycleJitters = Set<[Double]>()
        var velocityValues = Set<Double>()
        var detuneValues = Set<Double>()
        var filterValues = Set<Double>()
        for cycle in Int64(0)..<8 {
            let c = try compile(p, [pat], cycle: cycle)
            XCTAssertEqual(c, try compile(p, [pat], cycle: cycle))
            XCTAssertEqual(c.looseAlgorithmVersion, 1)
            XCTAssertEqual(c.cycleIndex, cycle)
            cycleJitters.insert(ons(c).map(\.timingJitterSeconds))
            for group in Dictionary(grouping: ons(c), by: \.occurrenceToken).values {
                XCTAssertEqual(Set(group.map(\.timingJitterSeconds)).count, 1)
            }
            for on in ons(c) {
                XCTAssertLessThanOrEqual(abs(on.timingJitterSeconds), 0.003)
                XCTAssertLessThanOrEqual(abs(on.effectiveVelocity - on.baseVelocity), 6.0 / 127 + 1e-15)
                XCTAssertLessThanOrEqual(abs(on.detuneCents), 3)
                XCTAssertLessThanOrEqual(abs(on.filterDelta), 0.02)
                XCTAssertTrue((0.01...1).contains(on.effectiveVelocity))
                XCTAssertEqual(on.baseVelocity, on.attackMode == .chuck ? 0.317 : 0.8)
                velocityValues.insert(on.effectiveVelocity)
                detuneValues.insert(on.detuneCents)
                filterValues.insert(on.filterDelta)
            }
            replay(c)
        }
        XCTAssertEqual(cycleJitters.count, 8)
        XCTAssertGreaterThan(velocityValues.count, 8)
        XCTAssertGreaterThan(detuneValues.count, 8)
        XCTAssertGreaterThan(filterValues.count, 8)
        let other = try pattern([0: arrow(), 1: arrow(), 3: .chuck(ChuckSize(0.317)), 6: arrow(8, .up)], bars: 2,
            settings: PatternSettings(swing: 0.37, humanize: .loose, spreadMilliseconds: 20, looseSeed: 1))
        XCTAssertNotEqual(ons(try compile(p, [pat])).map(\.effectiveVelocity), ons(try compile(p, [other])).map(\.effectiveVelocity))
        let differentIDs = try pattern([0: arrow(), 1: arrow()], bars: 2, settings: settings, id: "different")
        XCTAssertNotEqual(ons(try compile(p, [pat])).first?.timingJitterSeconds,
                          ons(try compile(p, [differentIDs])).first?.timingJitterSeconds)
    }

    func testLooseEarlyClampingAndVelocityEndpointsAndTightHasExactlyZeroVariations() throws {
        let p = try progression(bars: 1)
        var sawNegative = false
        var sawPositive = false
        for seed in UInt64(0)..<32 {
            let pat = try pattern([0: arrow(), 1: .chuck(ChuckSize(Double.leastNonzeroMagnitude)), 2: arrow(10)],
                settings: PatternSettings(humanize: .loose, spreadMilliseconds: 0, looseSeed: seed))
            let c = try compile(p, [pat])
            let first = try XCTUnwrap(ons(c).first)
            if first.timingJitterSeconds < 0 {
                sawNegative = true
                XCTAssertEqual(first.sampleOffset, 0, "Early shared jitter clips to ownership start")
            } else { sawPositive = true }
            for on in ons(c) {
                XCTAssertTrue((0.01...1).contains(on.effectiveVelocity))
                XCTAssertLessThan(on.sampleOffset, c.sampleCount)
            }
            replay(c)
        }
        XCTAssertTrue(sawNegative)
        XCTAssertTrue(sawPositive)
        let tight = try compile(p, [pattern([0: arrow(1), 1: arrow(10), 2: .chuck(ChuckSize(0.317))],
            settings: PatternSettings(humanize: .tight, looseSeed: .max))])
        XCTAssertTrue(ons(tight).allSatisfy {
            $0.baseVelocity == $0.effectiveVelocity && $0.timingJitterSeconds == 0 && $0.detuneCents == 0 && $0.filterDelta == 0
        })
        replay(tight)
    }

    func testAbsoluteCycleRoundingOnceIncludingJitterAtAllRatesAndAwkwardTempos() throws {
        let p = try progression()
        let span = try LoopSpan(start: 32, bars: 2)
        let pat = try pattern([0: arrow(), 1: arrow(8, .up), 3: .chuck(ChuckSize(0.317)), 7: arrow()], start: 2, bars: 2,
            settings: PatternSettings(swing: 0.37, humanize: .loose, spreadMilliseconds: 59.3, looseSeed: 777))
        var witnessedOffsetPlusJitterError = false
        var witnessedVaryingCycleLengths = false
        for rate in [44_100.0, 48_000, 96_000] {
            for tempo in [73.3, 137.17, 199.7] {
                let scale = rate * 60 / tempo / 4
                var lengths = Set<Int64>()
                for cycle in [Int64(0), 1, 2, 29, 332, 100_003] {
                    let c = try compile(p, [pat], tempo: tempo, rate: rate, loop: span, cycle: cycle)
                    let next = try compile(p, [pat], tempo: tempo, rate: rate, loop: span, cycle: cycle + 1)
                    let origin = Int64((Double(cycle * 32) * scale).rounded(.toNearestOrAwayFromZero))
                    let terminal = Int64((Double((cycle + 1) * 32) * scale).rounded(.toNearestOrAwayFromZero))
                    XCTAssertEqual(c.originSample, origin)
                    XCTAssertEqual(c.sampleCount, terminal - origin)
                    XCTAssertEqual(c.originSample + c.sampleCount, next.originSample)
                    lengths.insert(c.sampleCount)
                    for on in ons(c) {
                        let occurrence = try XCTUnwrap(c.occurrences.first { $0.token == on.occurrenceToken })
                        let slot = (occurrence.nominalStep % 16) / 2
                        let swing = slot.isMultiple(of: 2) ? 0 : 0.37
                        let u = Double(occurrence.nominalStep - span.start) + swing
                        let rawGrid = (Double(cycle * 32) + u) * scale
                        let totalSpread = on.attackMode == .chuck ? 0.012 : 0.0593
                        let delay = on.timingJitterSeconds + totalSpread * Double(on.onsetOrdinal) / 3
                        let ownerStart = Double(cycle * 32 + Int64(occurrence.ownershipStartStep - span.start)) * scale
                        let adjusted = max(ownerStart, rawGrid + delay * rate)
                        XCTAssertEqual(on.sampleOffset, Int64(adjusted.rounded(.toNearestOrAwayFromZero)) - origin)
                        if adjusted > ownerStart {
                            let incorrectlyRounded = Int64(rawGrid.rounded()) - origin + Int64((delay * rate).rounded())
                            witnessedOffsetPlusJitterError = witnessedOffsetPlusJitterError || incorrectlyRounded != on.sampleOffset
                        }
                        if on.attackMode == .chuck {
                            let gate = Int64(min(Double(terminal), adjusted + 0.04 * rate).rounded()) - origin
                            let off = try XCTUnwrap(offs(c).first { $0.instanceToken == on.instanceToken })
                            XCTAssertEqual(off.sampleOffset, gate)
                        }
                    }
                    replay(c)
                }
                witnessedVaryingCycleLengths = witnessedVaryingCycleLengths || lengths.count > 1
            }
        }
        XCTAssertTrue(witnessedOffsetPlusJitterError)
        XCTAssertTrue(witnessedVaryingCycleLengths, "Do not replay cycle-zero rounded lengths forever")
    }

    func testTerminalOffsShareBoundaryWithNextCycleOnsAndLocalTokensAreNotGenerations() throws {
        let p = try progression(bars: 1)
        let pat = try pattern([0: arrow()], settings: PatternSettings(spreadMilliseconds: 0))
        let a = try compile(p, [pat], tempo: 137.17, rate: 44_100, cycle: 123)
        let b = try compile(p, [pat], tempo: 137.17, rate: 44_100, cycle: 124)
        XCTAssertEqual(a.originSample + a.sampleCount, b.originSample)
        XCTAssertTrue(offs(a).allSatisfy { $0.sampleOffset == a.sampleCount })
        XCTAssertTrue(ons(b).allSatisfy { $0.sampleOffset == 0 })
        XCTAssertEqual(ons(a).map(\.instanceToken), ons(b).map(\.instanceToken))
        XCTAssertEqual(a.occurrences, b.occurrences)
        XCTAssertNotEqual(a.cycleIndex, b.cycleIndex)
        replay(a)
        replay(b)
    }

    func testExactErrorsForInvalidInputsOverflowPrecisionBoundaryAndCollapsedGates() throws {
        let p = try progression(bars: 1)
        let pat = try pattern([0: arrow()], settings: PatternSettings(spreadMilliseconds: 0))
        for tempo in [0.0, -1, .nan, .infinity] {
            assertMusicError(.invalidTempo) { _ = try compile(p, [pat], tempo: tempo) }
        }
        for rate in [0.0, -1, .nan, .infinity] {
            assertMusicError(.invalidSampleRate) { _ = try compile(p, [pat], rate: rate) }
        }
        assertMusicError(.invalidSpan) { _ = try compile(p, [pat], cycle: -1) }
        assertMusicError(.invalidSpan) { _ = try compile(p, [pat], loop: LoopSpan()) }
        for cycle in [Int64.max, Int64.max / 16, Int64(9_007_199_254_740_992 / 16)] {
            assertMusicError(.timingOverflow) { _ = try compile(p, [pat], cycle: cycle) }
        }
        for (tempo, rate) in [(Double.leastNonzeroMagnitude, 48_000.0),
                              (120, Double.greatestFiniteMagnitude), (1e30, 48_000),
                              (120, Double.leastNonzeroMagnitude)] {
            assertMusicError(.timingOverflow) { _ = try compile(p, [pat], tempo: tempo, rate: rate) }
        }
        let lastPrecise = Int64(9_007_199_254_740_992 / 16 - 1)
        let precise = try compile(p, [pat], tempo: 60, rate: 4, cycle: lastPrecise)
        XCTAssertEqual(precise.sampleCount, 16)
        replay(precise)
        let short = try progression([region(length: 1)], bars: 1)
        assertMusicError(.timingOverflow) { _ = try compile(short, [pat], rate: 1) }
        // Positive ownership interval, but a retained chuck's40ms gate rounds
        // to its onset. Reject rather than emit a zero-duration instance.
        assertMusicError(.timingOverflow) { _ = try compile(p, [pattern([0: .chuck(ChuckSize(0.4))])], rate: 1) }
    }

    func testTwelvePitchBoundaryAndThirteenthRejectedWithoutTruncation() throws {
        let twelve = [0, 3, 7, 10, 12, 15, 19, 22, 24, 27, 31, 34]
        let good = try progression([region(length: 16, pitches: twelve)], bars: 1)
        let pat = try pattern([0: arrow()], settings: PatternSettings(spreadMilliseconds: 0))
        let c = try compile(good, [pat])
        XCTAssertEqual(ons(c).count, 12)
        XCTAssertEqual(replay(c, through: 0).count, 12)
        replay(c)
        let bad = try progression([region(length: 16, pitches: twelve + [36])], bars: 1)
        assertCompilerError(.pitchCapacity) { _ = try compile(bad, [pat]) }
        // No-pattern delegation must retain even legacy behavior outside the
        // independent pattern branch's tighter admission contract.
        let legacy = try NoteEventCompiler.compile(bad, tempo: 120, sampleRate: 48_000, loop: LoopSpan(bars: 1))
        XCTAssertEqual(try PatternEventCompiler.compile(bad, arrangement: PatternArrangement(barCount: 1),
            tempo: 120, sampleRate: 48_000, loop: LoopSpan(bars: 1)), .legacy(legacy))
    }

    func testProductionCapacityAdmissionExactBoundariesOneOverAnd3072EventReplay() throws {
        // Current disjoint eight-bar ownership cannot generate >24 events per
        // sample or >12 held after pitch admission. Test the actual production
        // capacity primitive at32/33 too, without weakening the model to invent
        // impossible progressions or testing a reimplementation of the limits.
        XCTAssertNoThrow(try PatternEventCompiler.checkCapacities(eventCount: 3072, simultaneous: 32, held: 12))
        assertCompilerError(.eventCapacity) { try PatternEventCompiler.checkCapacities(eventCount: 3073, simultaneous: 32, held: 12) }
        assertCompilerError(.simultaneousCapacity) { try PatternEventCompiler.checkCapacities(eventCount: 3072, simultaneous: 33, held: 12) }
        assertCompilerError(.heldCapacity) { try PatternEventCompiler.checkCapacities(eventCount: 3072, simultaneous: 32, held: 13) }

        let compiled = try compile(progression(bars: 1), [pattern([0: arrow()])])
        let template = try XCTUnwrap(ons(compiled).first)
        func event(_ token: Int, _ sample: Int64, _ kind: NoteEventKind) -> PatternNoteEvent {
            PatternNoteEvent(sampleOffset: sample, kind: kind, pitch: UInt8(token % 12 + 60),
                ascendingRank: token % 12, onsetOrdinal: token % 12, harmonicToken: template.harmonicToken,
                occurrenceToken: PatternOccurrenceToken(rawValue: UInt16((token - 1) / 12 + 1)),
                instanceToken: PatternNoteToken(rawValue: UInt16(token)), baseVelocity: 0.8,
                effectiveVelocity: 0.8, timingJitterSeconds: 0, detuneCents: 0, filterDelta: 0, attackMode: .ordinary)
        }
        var events: [PatternNoteEvent] = []
        for group in 0..<128 {
            // Ordinals/ranks must be ascending at ties. Twelve valid tokens per
            // group, one exact off per instance, with all notes retired.
            let tokens = (1...12).map { group * 12 + $0 }.sorted { $0 % 12 < $1 % 12 }
            events += tokens.map { event($0, Int64(group * 2), .noteOn) }
            events += tokens.map { event($0, Int64(group * 2 + 1), .noteOff) }
        }
        XCTAssertEqual(events.count, 3072)
        XCTAssertNoThrow(try PatternEventCompiler.validate(events, sampleCount: 256))
        assertCompilerError(.eventCapacity) { try PatternEventCompiler.validate(events + [event(1537, 256, .noteOn)], sampleCount: 257) }
        let thirteen = (1...13).map { event($0, 0, .noteOn) }.sorted {
            if $0.occurrenceToken != $1.occurrenceToken { return $0.occurrenceToken.rawValue < $1.occurrenceToken.rawValue }
            return $0.onsetOrdinal < $1.onsetOrdinal
        }
        assertCompilerError(.heldCapacity) { try PatternEventCompiler.validate(thirteen, sampleCount: 256) }
        let missingOff = Array(events.dropLast())
        assertCompilerError(.invalidEventSequence) { try PatternEventCompiler.validate(missingOff, sampleCount: 256) }
        assertCompilerError(.invalidEventSequence) { try PatternEventCompiler.validate([event(1, 0, .noteOff)], sampleCount: 256) }
    }

    func testDensestMixedValidatedPlanRetainsEveryInstanceAndReplaysTwelveHeld() throws {
        let pitches = [0, 3, 7, 10, 12, 15, 19, 22, 24, 27, 31, 34]
        let regions = try (0..<128).map { try region("chord-\($0)", start: $0, length: 1, pitches: pitches) }
        let p = try progression(regions)
        let contents = try Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, try arrow()) })
        let c = try compile(p, [pattern(contents, settings: PatternSettings(spreadMilliseconds: 0))])
        // Eight occupied anchors in covered bar0, then 112 uncovered one-step
        // chords with 12 per-note RollNote occurrences each (8 + 112*12 = 1352).
        XCTAssertEqual(c.occurrences.count, 1352)
        XCTAssertEqual(c.harmonics.count, 128)
        XCTAssertEqual(ons(c).count, 1440)
        XCTAssertEqual(c.events.count, 2880)
        XCTAssertEqual(Dictionary(grouping: c.events, by: \.sampleOffset).values.map(\.count).max(), 24)
        XCTAssertEqual(replay(c, through: 96_000).count, 12)
        XCTAssertEqual(replay(c, through: c.sampleCount - 1).count, 12)
        replay(c)
    }
}
