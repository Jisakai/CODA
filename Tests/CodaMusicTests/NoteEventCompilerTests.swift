import Foundation
import XCTest
@testable import CodaMusic

final class NoteEventCompilerTests: MusicTestCase {
    func testBlockChordsBarBoundariesSortedVoiceMatchingAndOffBeforeOn() throws {
        let v = try vocabulary()
        let p = try Progression(regions: [region(pitches: [70, 67, 63, 60]), region("b", start: 16)], vocabulary: v)
        let result = try NoteEventCompiler.compile(p, tempo: 120, sampleRate: 48_000, loop: LoopSpan(bars: 2))
        XCTAssertEqual(result.sampleCount, 192_000)
        XCTAssertEqual(result.events.count, 16)
        let on = result.events.filter { $0.sampleOffset == 0 }
        XCTAssertEqual(on.map(\.pitch), [60, 63, 67, 70])
        XCTAssertEqual(on.map(\.voiceIndex), [0, 1, 2, 3])
        XCTAssertTrue(on.allSatisfy { $0.kind == .noteOn })
        let boundary = result.events.filter { $0.sampleOffset == 96_000 }
        XCTAssertEqual(boundary.map(\.kind), Array(repeating: .noteOff, count: 4) + Array(repeating: .noteOn, count: 4))
        XCTAssertEqual(boundary.prefix(4).map(\.voiceIndex), [0, 1, 2, 3])
        XCTAssertTrue(result.events.suffix(4).allSatisfy { $0.kind == .noteOff && $0.sampleOffset == result.sampleCount })
    }

    func testEachOffsetComesFromAbsoluteGridWithoutAccumulatedRounding() throws {
        let v = try vocabulary()
        let regions = try (0..<128).map { try region("r\($0)", start: $0, length: 1) }
        let p = try Progression(regions: regions, vocabulary: v)
        for tempo in [73.3, 124.0, 137.0, 199.7] {
            for rate in [44_100.0, 48_000.0, 96_000.0] {
                let loop = try LoopSpan()
                let result = try NoteEventCompiler.compile(p, tempo: tempo, sampleRate: rate, loop: loop)
                for event in result.events {
                    let step = event.regionIndex + (event.kind == .noteOff ? 1 : 0)
                    let expected = Int64((Double(step) * (rate * 60 / tempo / 4)).rounded(.toNearestOrAwayFromZero))
                    XCTAssertEqual(event.sampleOffset, expected)
                }
                XCTAssertEqual(result.sampleCount, Int64((128 * (rate * 60 / tempo / 4)).rounded(.toNearestOrAwayFromZero)))
                XCTAssertEqual(result, try NoteEventCompiler.compile(p, tempo: tempo, sampleRate: rate, loop: loop))
            }
        }
        let fractional = try NoteEventCompiler.compile(p, tempo: 137, sampleRate: 44_100, loop: LoopSpan())
        let repeatedRoundedStep = Int64((44_100.0 * 60 / 137 / 4).rounded()) * 128
        XCTAssertNotEqual(fractional.sampleCount, repeatedRoundedStep)
    }

    func testSilentSpansAndEmptyLoopDoNotCreateNotes() throws {
        let v = try vocabulary()
        let empty = try Progression(vocabulary: v)
        let silent = try NoteEventCompiler.compile(empty, tempo: 120, sampleRate: 48_000, loop: LoopSpan(bars: 1))
        XCTAssertTrue(silent.events.isEmpty)
        XCTAssertEqual(silent.sampleCount, 96_000)
        let p = try Progression(regions: [region(start: 4, length: 4), region("b", start: 16, length: 4)], vocabulary: v)
        let result = try NoteEventCompiler.compile(p, tempo: 120, sampleRate: 48_000, loop: LoopSpan(bars: 2))
        XCTAssertEqual(Set(result.events.map(\.sampleOffset)), Set([24_000, 48_000, 96_000, 120_000]))
        XCTAssertFalse(result.events.contains { $0.sampleOffset > 48_000 && $0.sampleOffset < 96_000 })
    }

    func testNonzeroLoopClipsSustainsAndExplicitlyReleasesAtLoopEnd() throws {
        let v = try vocabulary()
        let p = try Progression(regions: [region(start: 8, length: 32), region("outside", start: 64)], vocabulary: v)
        let loop = try LoopSpan(start: 16, bars: 1)
        let result = try NoteEventCompiler.compile(p, tempo: 120, sampleRate: 48_000, loop: loop)
        XCTAssertEqual(result.events.count, 8)
        XCTAssertTrue(result.events.prefix(4).allSatisfy { $0.sampleOffset == 0 && $0.kind == .noteOn })
        XCTAssertTrue(result.events.suffix(4).allSatisfy { $0.sampleOffset == result.sampleCount && $0.kind == .noteOff })
        XCTAssertTrue(result.events.allSatisfy { $0.regionIndex == 0 })
    }

    func testRejectsInvalidTempoRateLoopAndUnrepresentableOrCollapsedTiming() throws {
        let v = try vocabulary()
        let p = try Progression(totalSteps: 16, regions: [region(length: 1)], vocabulary: v)
        let loop = try LoopSpan(bars: 1)
        for tempo in [0, -1, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try NoteEventCompiler.compile(p, tempo: tempo, sampleRate: 48_000, loop: loop))
        }
        for rate in [0, -1, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try NoteEventCompiler.compile(p, tempo: 120, sampleRate: rate, loop: loop))
        }
        XCTAssertThrowsError(try NoteEventCompiler.compile(p, tempo: 120, sampleRate: 48_000, loop: LoopSpan()))
        XCTAssertThrowsError(try NoteEventCompiler.compile(p, tempo: Double.leastNonzeroMagnitude, sampleRate: 48_000, loop: loop))
        XCTAssertThrowsError(try NoteEventCompiler.compile(p, tempo: 120, sampleRate: Double.greatestFiniteMagnitude, loop: loop))
        XCTAssertThrowsError(try NoteEventCompiler.compile(p, tempo: 1e20, sampleRate: 48_000, loop: loop))
        XCTAssertThrowsError(try NoteEventCompiler.compile(p, tempo: 120, sampleRate: 1, loop: loop))
        XCTAssertThrowsError(try NoteEventCompiler.compile(p, tempo: 120, sampleRate: 48_000, loop: loop, cycleIndex: -1))
        XCTAssertThrowsError(try NoteEventCompiler.compile(p, tempo: 120, sampleRate: 48_000, loop: loop, cycleIndex: Int64.max))
    }

    func testConsecutiveFractionalCyclesShareAbsoluteOriginWithoutLoopRoundingDrift() throws {
        let v = try vocabulary()
        let p = try Progression(regions: [region(length: 128)], vocabulary: v)
        let loop = try LoopSpan()
        let samplesPerStep = 44_100.0 * 60 / 137 / 4
        var boundary: Int64 = 0
        var lengths = Set<Int64>()
        for cycle in 0..<100 {
            let compiled = try NoteEventCompiler.compile(p, tempo: 137, sampleRate: 44_100,
                                                         loop: loop, cycleIndex: Int64(cycle))
            XCTAssertEqual(compiled.originSample, boundary)
            boundary = compiled.originSample + compiled.sampleCount
            XCTAssertEqual(boundary, Int64((Double((cycle + 1) * 128) * samplesPerStep).rounded()))
            lengths.insert(compiled.sampleCount)
            XCTAssertTrue(compiled.events.suffix(4).allSatisfy { $0.sampleOffset == compiled.sampleCount && $0.kind == .noteOff })
        }
        XCTAssertEqual(lengths.count, 2, "Cycle lengths must carry the fractional sample remainder")
    }
}
