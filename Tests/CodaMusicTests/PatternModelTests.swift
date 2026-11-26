import XCTest
@testable import CodaMusic

final class PatternModelTests: XCTestCase {
    func testAllTenLevelsShareLengthBaseAndPercentageReadout() throws {
        for value in 1...10 {
            let level = try ArrowLevel(value)
            XCTAssertEqual(level.value, value)
            XCTAssertEqual(level.normalizedLength, Double(value) / 10)
            XCTAssertEqual(level.baseVelocity, level.normalizedLength)
            XCTAssertEqual(level.readout, "v\(value * 10)")
            XCTAssertEqual(try ArrowLevel.from(normalizedLength: level.normalizedLength), level)
            for direction in [StrokeDirection.down, .up] {
                let stroke = try PatternStroke(id: "s", content: .arrow(direction: direction, level: level))
                XCTAssertEqual(stroke.baseVelocity, level.normalizedLength)
            }
        }
        for invalid in [Int.min, -1, 0, 11, Int.max] {
            XCTAssertThrowsError(try ArrowLevel(invalid))
        }
    }

    func testLengthConversionAbsenceEndpointsTiesClampsAndExtremes() throws {
        for length in [-Double.greatestFiniteMagnitude, -1, -0.0, 0] {
            XCTAssertNil(try ArrowLevel.from(normalizedLength: length))
        }
        let cases: [(Double, Int)] = [
            (.leastNonzeroMagnitude, 1), (.leastNormalMagnitude, 1),
            (0.049, 1), (0.05, 1), (0.1, 1), (0.149, 1),
            (0.15, 2), (0.25, 3), (0.35, 4), (0.45, 5),
            (0.55, 6), (0.65, 7), (0.75, 8), (0.85, 9), (0.95, 10),
            (0.949, 9), (1, 10), (1.01, 10), (.greatestFiniteMagnitude, 10)
        ]
        for (length, expected) in cases {
            XCTAssertEqual(try ArrowLevel.from(normalizedLength: length)?.value, expected, "\(length)")
        }
        for length in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try ArrowLevel.from(normalizedLength: length)) {
                XCTAssertEqual($0 as? PatternError, .nonfiniteLength)
            }
        }
    }

    func testChuckRetainsContinuousSizeAndTinyPositiveBaseVelocity() throws {
        for size in [Double.leastNonzeroMagnitude, 0.0173, 0.333333, 0.9876, 1] {
            let chuck = try ChuckSize(size)
            let stroke = try PatternStroke(id: "x", content: .chuck(chuck))
            XCTAssertEqual(chuck.normalizedSize, size)
            XCTAssertEqual(chuck.baseVelocity, size)
            XCTAssertEqual(stroke.baseVelocity, size)
        }
        for size in [0, -0.0, -0.1, 1.0001, Double.greatestFiniteMagnitude, .nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try ChuckSize(size))
        }
    }

    func testBarRangesRejectOverflowAndInvalidBounds() throws {
        for (start, length) in [(-1, 1), (0, 0), (0, -1), (8, 1), (0, 9),
                                (Int.max, 1), (1, Int.max), (Int.min, Int.min)] {
            XCTAssertThrowsError(try PatternBarRange(start: start, length: length))
        }
        XCTAssertEqual(try PatternBarRange(start: 0, length: 8).end, 8)
        XCTAssertEqual(try PatternBarRange(start: 7, length: 1).end, 8)
        for count in [Int.min, -1, 0, 9, Int.max] {
            XCTAssertThrowsError(try PatternArrangement(barCount: count))
        }
        for count in 1...8 { XCTAssertEqual(try PatternArrangement(barCount: count).barCount, count) }
    }

    func testRegionsRequireEightSlotsAndNonemptyUniqueIDsInSeparateNamespaces() throws {
        let range = try PatternBarRange(start: 0, length: 1)
        let settings = try PatternSettings()
        let stroke = try PatternStroke(id: "shared", content: .chuck(ChuckSize(0.37)))
        XCTAssertThrowsError(try PatternStroke(id: "", content: stroke.content))
        for count in [0, 7, 9] {
            XCTAssertThrowsError(try PatternRegion(id: "r", range: range,
                slots: Array(repeating: nil, count: count), settings: settings))
        }
        var slots: [PatternStroke?] = Array(repeating: nil, count: 8)
        XCTAssertThrowsError(try PatternRegion(id: "", range: range, slots: slots, settings: settings))
        slots[0] = stroke
        let first = try PatternRegion(id: "shared", range: range, slots: slots, settings: settings)
        XCTAssertNoThrow(try PatternArrangement(regions: [first])) // namespaces are separate
        slots[7] = stroke
        XCTAssertThrowsError(try PatternRegion(id: "r", range: range, slots: slots, settings: settings))
        let second = try PatternRegion(id: "other", range: PatternBarRange(start: 1, length: 1),
                                       slots: first.slots, settings: settings)
        XCTAssertThrowsError(try PatternArrangement(regions: [first, second])) {
            XCTAssertEqual($0 as? PatternError, .duplicateStrokeID)
        }
        let duplicateRegion = try PatternRegion(id: first.id, range: second.range,
            slots: Array(repeating: nil, count: 8), settings: settings)
        XCTAssertThrowsError(try PatternArrangement(regions: [first, duplicateRegion])) {
            XCTAssertEqual($0 as? PatternError, .duplicateRegionID)
        }
    }

    func testHalfOpenRangesAllowTouchingAndSortButRejectOverlapAndOutsideArrangement() throws {
        func region(_ id: String, _ start: Int, _ length: Int) throws -> PatternRegion {
            try PatternRegion(id: id, range: PatternBarRange(start: start, length: length),
                              slots: Array(repeating: nil, count: 8), settings: PatternSettings())
        }
        let a = try region("a", 0, 2)
        let b = try region("b", 2, 2)
        XCTAssertEqual(try PatternArrangement(barCount: 4, regions: [b, a]).regions, [a, b])
        XCTAssertThrowsError(try PatternArrangement(regions: [a, region("c", 1, 2)]))
        XCTAssertThrowsError(try PatternArrangement(barCount: 3, regions: [b]))
        XCTAssertNoThrow(try PatternArrangement(barCount: 4, regions: [b])) // uncovered bars allowed
    }

    func testScopeDividesGridStepsAndPreservesAbsoluteStart() throws {
        XCTAssertEqual(PatternDefaults.defaultScope, .wholeLoop)
        let loop = try LoopSpan(start: 32, bars: 2)
        let range = try PatternDefaults.defaultScope.resolve(loop: loop, barCount: 8)
        XCTAssertEqual(range.start, 2)
        XCTAssertEqual(range.length, 2)
        XCTAssertEqual(range.end, 4)
        XCTAssertNoThrow(try PatternDefaults.defaultScope.resolve(loop: loop, barCount: 4))
        XCTAssertThrowsError(try PatternDefaults.defaultScope.resolve(loop: loop, barCount: 3))
        for count in [0, 9, Int.max] {
            XCTAssertThrowsError(try PatternDefaults.defaultScope.resolve(loop: loop, barCount: count))
        }
        XCTAssertEqual(try PatternDefaults.defaultScope.resolve(loop: LoopSpan(start: 112, bars: 1), barCount: 8),
                       try PatternBarRange(start: 7, length: 1))
    }

    func testSettingsDefaultsBoundariesNonfiniteAndLooseMetadata() throws {
        let defaults = try PatternSettings()
        XCTAssertEqual(defaults.swing, 0)
        XCTAssertEqual(defaults.humanize, .tight)
        XCTAssertEqual(defaults.spreadMilliseconds, 20)
        XCTAssertEqual(defaults.looseSeed, 0)
        XCTAssertEqual(defaults.looseAlgorithmVersion, 1)
        for swing in [0.0, 1.0] {
            for spread in [0.0, 60.0] {
                let settings = try PatternSettings(swing: swing, humanize: .loose,
                    spreadMilliseconds: spread, looseSeed: .max)
                XCTAssertEqual(settings.swing, swing)
                XCTAssertEqual(settings.spreadMilliseconds, spread)
                XCTAssertEqual(settings.humanize, .loose)
                XCTAssertEqual(settings.looseSeed, UInt64.max)
            }
        }
        for invalid in [-0.001, 1.001, Double.greatestFiniteMagnitude, .nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try PatternSettings(swing: invalid))
        }
        for invalid in [-0.001, 60.001, Double.greatestFiniteMagnitude, .nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try PatternSettings(spreadMilliseconds: invalid))
        }
        XCTAssertEqual(PatternDefaults.maximumSwingDelaySteps, 1)
        XCTAssertEqual(PatternDefaults.looseTimingMilliseconds, 3)
        XCTAssertEqual(PatternDefaults.looseVelocityDelta, 6.0 / 127)
        XCTAssertEqual(PatternDefaults.looseDetuneCents, 3)
        XCTAssertEqual(PatternDefaults.looseFilterDelta, 0.02)
        XCTAssertEqual(PatternDefaults.looseEffectiveVelocityRange, 0.01...1.0)
        XCTAssertEqual(PatternDefaults.chuckRakeMilliseconds, 12)
        XCTAssertEqual(PatternDefaults.chuckGateMilliseconds, 40)
        XCTAssertEqual(PatternDefaults.uncoveredBaseVelocity, 0.8)
    }

    func testPopRockIsReusableEightSlotDataWithExplicitOccupiedIdentities() throws {
        let preset = PatternPreset.popRock
        let level = try ArrowLevel(8)
        let d = PatternStroke.Content.arrow(direction: .down, level: level)
        let u = PatternStroke.Content.arrow(direction: .up, level: level)
        XCTAssertEqual(preset.slots, [d, nil, d, u, nil, u, d, u])
        let ids = ["s0", "s2", "s3", "s5", "s6", "s7"]
        let a = try preset.instantiate(id: "a", range: PatternBarRange(start: 0, length: 1),
                                      occupiedStrokeIDs: ids, settings: PatternSettings())
        let b = try preset.instantiate(id: "b", range: PatternBarRange(start: 1, length: 1),
                                      occupiedStrokeIDs: ids.map { "b-" + $0 }, settings: PatternSettings())
        XCTAssertEqual(a.slots.compactMap { $0?.id }, ids)
        XCTAssertEqual(a.slots.map { $0?.content }, preset.slots)
        XCTAssertTrue(a.slots.compactMap { $0?.baseVelocity }.allSatisfy { $0 == 0.8 })
        XCTAssertNoThrow(try PatternArrangement(regions: [a, b]))
        for badIDs in [[], Array(ids.dropLast()), ids + ["extra"], Array(repeating: "same", count: 6),
                       ["", "1", "2", "3", "4", "5"]] {
            XCTAssertThrowsError(try preset.instantiate(id: "r", range: a.range,
                occupiedStrokeIDs: badIDs, settings: a.settings))
        }
        XCTAssertThrowsError(try PatternPreset(name: "bad", slots: []))
    }
}
