import Foundation
import XCTest
@testable import CodaMusic

class PatternCompilerTestCase: MusicTestCase {
    func arrow(_ level: Int = 8, _ direction: StrokeDirection = .down) throws -> PatternStroke.Content {
        .arrow(direction: direction, level: try ArrowLevel(level))
    }

    func pattern(_ contents: [Int: PatternStroke.Content] = [:], start: Int = 0, bars: Int = 1,
                 settings: PatternSettings? = nil, id: String = "pattern") throws -> PatternRegion {
        var slots = [PatternStroke?](repeating: nil, count: 8)
        for (slot, content) in contents {
            slots[slot] = try PatternStroke(id: "\(id)-\(slot)", content: content)
        }
        return try PatternRegion(id: id, range: PatternBarRange(start: start, length: bars), slots: slots,
                                 settings: settings ?? PatternSettings())
    }

    func progression(_ regions: [ChordRegion]? = nil, bars: Int = 8) throws -> Progression {
        try Progression(totalSteps: bars * 16, regions: regions ?? [region(length: bars * 16,
            pitches: [60, 63, 67, 70])], vocabulary: vocabulary())
    }

    func compile(_ p: Progression, _ patterns: [PatternRegion], tempo: Double = 120,
                 rate: Double = 48_000, loop: LoopSpan? = nil, cycle: Int64 = 0) throws -> CompiledPatternLoop {
        let result = try PatternEventCompiler.compile(p,
            arrangement: PatternArrangement(barCount: p.totalSteps / 16, regions: patterns),
            tempo: tempo, sampleRate: rate, loop: loop ?? LoopSpan(bars: p.totalSteps / 16), cycleIndex: cycle)
        guard case .pattern(let compiled) = result else {
            throw PatternCompilerError.invalidEventSequence
        }
        return compiled
    }

    func ons(_ loop: CompiledPatternLoop) -> [PatternNoteEvent] { loop.events.filter { $0.kind == .noteOn } }
    func offs(_ loop: CompiledPatternLoop) -> [PatternNoteEvent] { loop.events.filter { $0.kind == .noteOff } }

    func assertMusicError(_ expected: MusicError, _ body: () throws -> Void,
                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? MusicError, expected, file: file, line: line) }
    }

    func assertCompilerError(_ expected: PatternCompilerError, _ body: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? PatternCompilerError, expected, file: file, line: line) }
    }

    /// Replay the REAL compiler output. Exact tokens, not pitch/rank, own offs.
    @discardableResult
    func replay(_ loop: CompiledPatternLoop, through sample: Int64? = nil,
                file: StaticString = #filePath, line: UInt = #line) -> [PatternNoteToken: PatternNoteEvent] {
        var active: [PatternNoteToken: PatternNoteEvent] = [:]
        var used = Set<PatternNoteToken>()
        for event in loop.events where event.sampleOffset <= (sample ?? loop.sampleCount) {
            if event.kind == .noteOn {
                XCTAssertTrue(used.insert(event.instanceToken).inserted, file: file, line: line)
                XCTAssertFalse(active.values.contains { $0.pitch == event.pitch }, file: file, line: line)
                active[event.instanceToken] = event
                XCTAssertLessThanOrEqual(active.count, 12, file: file, line: line)
            } else {
                let on = active.removeValue(forKey: event.instanceToken)
                XCTAssertNotNil(on, file: file, line: line)
                XCTAssertEqual(on?.pitch, event.pitch, file: file, line: line)
                XCTAssertEqual(on?.harmonicToken, event.harmonicToken, file: file, line: line)
                XCTAssertEqual(on?.occurrenceToken, event.occurrenceToken, file: file, line: line)
                XCTAssertLessThan(on?.sampleOffset ?? .max, event.sampleOffset, file: file, line: line)
            }
        }
        if sample == nil { XCTAssertTrue(active.isEmpty, file: file, line: line) }
        return active
    }
}

final class PatternEventCompilerTests: PatternCompilerTestCase {
    func testCheckedDimensionMismatchPrecedesEveryOtherErrorAndLegacyDelegation() throws {
        let p = try progression(bars: 1)
        for patterns in [[], [try pattern([0: arrow()])]] {
            let a = try PatternArrangement(barCount: 2, regions: patterns)
            assertCompilerError(.dimensionMismatch) {
                _ = try PatternEventCompiler.compile(p, arrangement: a, tempo: .nan,
                    sampleRate: -.infinity, loop: LoopSpan(), cycleIndex: .max)
            }
        }
    }

    func testNoCoverageDelegatesExactlyIncludingNonzeroLoopAndCycleErrors() throws {
        let p = try progression([region(start: 8, length: 64), region("tail", start: 96)])
        let span = try LoopSpan(start: 32, bars: 2)
        for patterns in [[], [try pattern([0: arrow()], start: 0)]] {
            let a = try PatternArrangement(regions: patterns)
            for cycle in [Int64(0), 1, 99, 1_000_000_001] {
                for rate in [44_100.0, 48_000, 96_000] {
                    let legacy = try NoteEventCompiler.compile(p, tempo: 137.3, sampleRate: rate, loop: span, cycleIndex: cycle)
                    XCTAssertEqual(try PatternEventCompiler.compile(p, arrangement: a, tempo: 137.3,
                        sampleRate: rate, loop: span, cycleIndex: cycle), .legacy(legacy))
                }
            }
            for (tempo, rate, cycle, error) in [
                (Double.nan, 48_000.0, Int64(0), MusicError.invalidTempo),
                (120, Double.infinity, 0, .invalidSampleRate), (120, 48_000, -1, .invalidSpan),
                (120, 48_000, Int64.max, .timingOverflow), (1e30, 48_000, 0, .timingOverflow)
            ] {
                assertMusicError(error) { _ = try PatternEventCompiler.compile(p, arrangement: a,
                    tempo: tempo, sampleRate: rate, loop: span, cycleIndex: cycle) }
                assertMusicError(error) { _ = try NoteEventCompiler.compile(p,
                    tempo: tempo, sampleRate: rate, loop: span, cycleIndex: cycle) }
            }
        }
        let short = try progression(bars: 1)
        assertMusicError(.invalidSpan) { _ = try PatternEventCompiler.compile(short,
            arrangement: PatternArrangement(barCount: 1), tempo: 120, sampleRate: 48_000, loop: LoopSpan()) }
    }

    func testAllTenArrowLevelsThroughActualEditorToCompilerAndNonzeroScope() throws {
        let p = try progression()
        let span = try LoopSpan(start: 32, bars: 2)
        let range = try PatternDefaults.defaultScope.resolve(loop: span, barCount: 8)
        XCTAssertEqual(range, try PatternBarRange(start: 2, length: 2))
        var editor = PatternEditor(try PatternArrangement(regions: [pattern([0: arrow()], start: 2, bars: 2)]))
        for value in 1...10 {
            let level = try XCTUnwrap(try ArrowLevel.from(normalizedLength: Double(value) / 10))
            try editor.apply([.setStroke(id: "pattern", slot: 0,
                content: .arrow(direction: .down, level: level), newStrokeID: nil)])
            let result = try PatternEventCompiler.compile(p, arrangement: editor.arrangement,
                tempo: 120, sampleRate: 48_000, loop: span)
            guard case .pattern(let compiled) = result else { return XCTFail("Applied scope must compile") }
            XCTAssertEqual(ons(compiled).count, 8)
            for on in ons(compiled) {
                XCTAssertEqual(on.baseVelocity, level.normalizedLength)
                XCTAssertEqual(on.effectiveVelocity, level.baseVelocity)
            }
            XCTAssertEqual(level.readout, "v\(value * 10)")
            XCTAssertEqual(compiled.occurrences.map(\.nominalStep), [32, 48])
            replay(compiled)
        }
    }

    func testUpDownOrderingRankOrdinalZeroDefaultAndMaximumTotalSpread() throws {
        let p = try progression(bars: 1)
        for direction in [StrokeDirection.down, .up] {
            for spread in [0.0, 20, 60] {
                let c = try compile(p, [pattern([0: arrow(8, direction)], settings: PatternSettings(spreadMilliseconds: spread))])
                let attacks = ons(c)
                XCTAssertEqual(attacks.map(\.pitch), direction == .down ? [60, 63, 67, 70] : [70, 67, 63, 60])
                XCTAssertEqual(attacks.map(\.ascendingRank), direction == .down ? [0, 1, 2, 3] : [3, 2, 1, 0])
                XCTAssertEqual(attacks.map(\.onsetOrdinal), [0, 1, 2, 3])
                XCTAssertEqual(attacks.map(\.sampleOffset), (0..<4).map {
                    Int64((spread / 1000 * Double($0) / 3 * 48_000).rounded())
                })
                XCTAssertEqual(Set(attacks.map(\.harmonicToken)).count, 1)
                XCTAssertEqual(Set(attacks.map(\.occurrenceToken)).count, 1)
                XCTAssertEqual(Set(attacks.map(\.instanceToken)).count, 4)
                XCTAssertTrue(offs(c).allSatisfy { $0.sampleOffset == c.sampleCount })
                replay(c)
            }
        }
        // Progression vocabulary requires >=2 pitch classes, so a singleton
        // cannot pass its public initializer. Exercise the compiler's actual
        // singleton spread primitive rather than bypassing model validation.
        for total in [0.0, 20, 60] {
            XCTAssertEqual(PatternEventCompiler.onsetSpreadMilliseconds(ordinal: 0, noteCount: 1, total: total), 0)
            XCTAssertEqual(PatternEventCompiler.onsetSpreadMilliseconds(ordinal: 0, noteCount: 4, total: total), 0)
            XCTAssertEqual(PatternEventCompiler.onsetSpreadMilliseconds(ordinal: 3, noteCount: 4, total: total), total)
        }
    }

    func testEmptySlotsSustainAndAppliedAllEmptyIsNotAbsentEvenWithoutChords() throws {
        let p = try progression(bars: 1)
        let c = try compile(p, [pattern([0: arrow()])])
        XCTAssertEqual(ons(c).count, 4)
        XCTAssertEqual(offs(c).count, 4)
        XCTAssertTrue(offs(c).allSatisfy { $0.sampleOffset == 96_000 })
        XCTAssertEqual(replay(c, through: 80_000).count, 4)
        let silent = try compile(p, [pattern()])
        XCTAssertTrue(silent.events.isEmpty)
        XCTAssertTrue(silent.occurrences.isEmpty)
        XCTAssertEqual(silent.sampleCount, 96_000)
        let empty = try compile(progression([], bars: 1), [pattern()])
        XCTAssertTrue(empty.events.isEmpty)
        XCTAssertEqual(empty.sampleCount, 96_000)
        replay(c)
    }

    func testActualPopRockPresetDataRepeatsEightSlotPhaseWithDirectionalOnsets() throws {
        let p = try progression(bars: 2)
        let pat = try PatternPreset.popRock.instantiate(id: "pop", range: PatternBarRange(start: 0, length: 2),
            occupiedStrokeIDs: (0..<6).map { "pop-\($0)" }, settings: PatternSettings(spreadMilliseconds: 0))
        let c = try compile(p, [pat])
        XCTAssertEqual(c.occurrences.map(\.nominalStep), [0, 4, 6, 10, 12, 14, 16, 20, 22, 26, 28, 30])
        for occurrence in c.occurrences {
            let slot = (occurrence.nominalStep % 16) / 2
            let up = [3, 5, 7].contains(slot)
            let attacks = ons(c).filter { $0.occurrenceToken == occurrence.token }
            XCTAssertEqual(attacks.map(\.pitch), up ? [70, 67, 63, 60] : [60, 63, 67, 70])
            XCTAssertTrue(attacks.allSatisfy { $0.baseVelocity == 0.8 && $0.effectiveVelocity == 0.8 })
        }
        replay(c)
    }

    func testOddChordChangesRestsAndAbsoluteBarPhaseSelectNominalChord() throws {
        let p = try progression([region(length: 3), region("b", start: 3, length: 4),
                                 region("c", start: 10, length: 6)], bars: 1)
        let contents = try Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, try arrow()) })
        let c = try compile(p, [pattern(contents, settings: PatternSettings(spreadMilliseconds: 0))])
        XCTAssertEqual(c.occurrences.map(\.nominalStep), [0, 2, 4, 6, 10, 12, 14])
        let nominalByToken = Dictionary(uniqueKeysWithValues: c.occurrences.map { ($0.token, $0.nominalStep) })
        for event in ons(c) {
            let anchor = try XCTUnwrap(nominalByToken[event.occurrenceToken])
            XCTAssertEqual(event.harmonicToken.rawValue, anchor < 3 ? 1 : (anchor < 7 ? 2 : 3))
        }
        XCTAssertFalse(c.events.contains { $0.sampleOffset > 42_000 && $0.sampleOffset < 60_000 })
        let swung = try compile(p, [pattern([0: arrow(), 1: arrow()], settings: PatternSettings(swing: 1, spreadMilliseconds: 0))])
        // Slot1 belongs to chord a at step2; delayed to its end3 -> omitted,
        // never reassigned to chord b at step3.
        XCTAssertEqual(ons(swung).count, 4)
        XCTAssertTrue(offs(swung).allSatisfy { $0.sampleOffset == 18_000 })
        replay(c)
        replay(swung)
    }

    func testMixedCoverageClipsBlocksEnteringHasNoAttackAndExitRestoresPointEight() throws {
        let p = try progression([region(start: 1, length: 60)])
        let c = try compile(p, [pattern([2: arrow(3)], start: 1,
            settings: PatternSettings(humanize: .loose))])
        XCTAssertEqual(c.occurrences.map(\.nominalStep), [1, 20, 32])
        XCTAssertEqual(c.occurrences.map(\.ownershipEndStep), [16, 32, 61])
        let attacks = ons(c)
        XCTAssertEqual(attacks.filter { $0.sampleOffset == 6_000 }.count, 4)
        XCTAssertFalse(attacks.contains { $0.sampleOffset == 96_000 })
        XCTAssertEqual(attacks.filter { $0.sampleOffset == 192_000 }.count, 4)
        for on in attacks where c.occurrences.first(where: { $0.token == on.occurrenceToken })?.patternRegionID == nil {
            XCTAssertEqual(on.baseVelocity, 0.8)
            XCTAssertEqual(on.effectiveVelocity, 0.8)
            XCTAssertEqual(on.detuneCents, 0)
            XCTAssertEqual(on.filterDelta, 0)
            XCTAssertEqual(on.timingJitterSeconds, 0)
        }
        XCTAssertEqual(replay(c, through: 96_000).count, 0)
        XCTAssertEqual(replay(c, through: 150_000).count, 4)
        XCTAssertEqual(replay(c, through: 192_000).count, 4)
        let empty = try compile(p, [pattern(start: 1)])
        XCTAssertEqual(empty.occurrences.map(\.nominalStep), [1, 32])
        XCTAssertEqual(replay(empty, through: 150_000).count, 0)
        let clippedLoop = try compile(p, [pattern([0: arrow()], start: 2)], loop: LoopSpan(start: 32, bars: 1))
        XCTAssertTrue(clippedLoop.occurrences.allSatisfy { $0.ownershipStartStep == 32 && $0.ownershipEndStep == 48 })
        XCTAssertTrue(offs(clippedLoop).allSatisfy { $0.sampleOffset == clippedLoop.sampleCount })
        replay(c)
        replay(empty)
        replay(clippedLoop)
    }

    func testAdjacentCoverageIsDistinctOwnershipAndLoopDoesNotRestartPhaseAtChord() throws {
        let p = try progression([region(start: 30, length: 28)])
        let c = try compile(p, [pattern([1: arrow(2)], start: 2, id: "a"),
                                pattern([0: arrow(7)], start: 3, id: "b")], loop: LoopSpan(start: 32, bars: 2))
        XCTAssertEqual(c.occurrences.map(\.nominalStep), [34, 48])
        XCTAssertEqual(c.occurrences.map(\.ownershipStartStep), [32, 48])
        XCTAssertEqual(Set(ons(c).map(\.harmonicToken)).count, 1)
        XCTAssertEqual(Set(ons(c).map(\.occurrenceToken)).count, 2)
        XCTAssertEqual(replay(c, through: 0).count, 0)
        XCTAssertTrue(offs(c).contains { $0.sampleOffset == 96_000 })
        replay(c)
    }
}
