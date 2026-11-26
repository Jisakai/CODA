import XCTest
@testable import CodaMusic

final class PatternEditorTests: XCTestCase {
    private func region(_ id: String = "a", start: Int = 0, length: Int = 1) throws -> PatternRegion {
        try PatternPreset.popRock.instantiate(id: id, range: PatternBarRange(start: start, length: length),
            occupiedStrokeIDs: (0..<6).map { "\(id)-\($0)" }, settings: PatternSettings())
    }

    private func content(_ level: Int, direction: StrokeDirection = .down) throws -> PatternStroke.Content {
        .arrow(direction: direction, level: try ArrowLevel(level))
    }

    func testAllTenConvertedLevelsEditRenderBaseAndReadoutRemainIdentical() throws {
        var editor = PatternEditor(try PatternArrangement(regions: [region()]))
        for value in 1...10 {
            let level = try XCTUnwrap(ArrowLevel.from(normalizedLength: Double(value) / 10))
            for direction in [StrokeDirection.down, .up] {
                try editor.apply([.setStroke(id: "a", slot: 0,
                    content: .arrow(direction: direction, level: level), newStrokeID: nil)])
                let stroke = try XCTUnwrap(editor.arrangement.regions[0].slots[0])
                guard case .arrow(let storedDirection, let storedLevel) = stroke.content else {
                    return XCTFail("Expected arrow")
                }
                XCTAssertEqual(stroke.id, "a-0")
                XCTAssertEqual(storedDirection, direction)
                XCTAssertEqual(storedLevel.value, value)
                XCTAssertEqual(storedLevel.normalizedLength, Double(value) / 10)
                XCTAssertEqual(stroke.baseVelocity, storedLevel.normalizedLength)
                XCTAssertEqual(storedLevel.readout, "v\(value * 10)")
            }
        }
    }

    func testPreviewAndCompleteUndoRedoRestoreSettingsSlotsRangesIDsAndBarCount() throws {
        let empty = try PatternArrangement()
        var editor = PatternEditor(empty)
        let a = try region()
        try editor.apply([.add(a)])
        let added = editor.arrangement
        let settings = try PatternSettings(swing: 0.7, humanize: .loose, spreadMilliseconds: 60, looseSeed: 123)
        let edits: [PatternEdit] = [
            .resize(id: "a", range: try PatternBarRange(start: 2, length: 2)),
            .settings(id: "a", settings),
            .setStroke(id: "a", slot: 0, content: .chuck(try ChuckSize(0.317)), newStrokeID: nil),
            .setStroke(id: "a", slot: 1, content: try content(1, direction: .up), newStrokeID: "new"),
            .removeStroke(id: "a", slot: 2), .barCount(4)
        ]
        let preview = try editor.preview(edits)
        XCTAssertEqual(editor.arrangement, added)
        XCTAssertTrue(editor.canUndo)
        XCTAssertFalse(editor.canRedo)
        XCTAssertEqual(preview.barCount, 4)
        XCTAssertEqual(preview.regions[0].range, try PatternBarRange(start: 2, length: 2))
        XCTAssertEqual(preview.regions[0].settings, settings)
        XCTAssertEqual(preview.regions[0].slots[0]?.id, "a-0")
        XCTAssertEqual(preview.regions[0].slots[0]?.baseVelocity, 0.317)
        XCTAssertEqual(preview.regions[0].slots[1]?.id, "new")
        XCTAssertNil(preview.regions[0].slots[2])
        try editor.apply(edits)
        XCTAssertEqual(editor.arrangement, preview)
        try editor.apply([.duplicate(id: "a", newID: "b", range: PatternBarRange(start: 0, length: 2),
            occupiedStrokeIDs: (0..<6).map { "b-\($0)" })])
        let duplicated = editor.arrangement
        let b = duplicated.regions[0]
        XCTAssertEqual(b.id, "b")
        XCTAssertEqual(b.settings, settings)
        XCTAssertEqual(b.slots.map { $0?.content }, preview.regions[0].slots.map { $0?.content })
        XCTAssertEqual(b.slots.compactMap { $0?.id }, (0..<6).map { "b-\($0)" })
        try editor.apply([.delete(id: "a")])
        let deleted = editor.arrangement
        for expected in [duplicated, preview, added, empty] {
            XCTAssertTrue(editor.undo())
            XCTAssertEqual(editor.arrangement, expected)
        }
        XCTAssertFalse(editor.undo())
        for expected in [added, preview, duplicated, deleted] {
            XCTAssertTrue(editor.redo())
            XCTAssertEqual(editor.arrangement, expected)
        }
        XCTAssertFalse(editor.redo())
    }

    func testFinalCandidateAllowsIntermediateOverlapAndDimensionChange() throws {
        let initial = try PatternArrangement(barCount: 2, regions: [region(), region("b", start: 1)])
        var editor = PatternEditor(initial)
        let edits: [PatternEdit] = [
            .resize(id: "a", range: try PatternBarRange(start: 0, length: 2)),
            .resize(id: "b", range: try PatternBarRange(start: 2, length: 2)), .barCount(4)
        ]
        let preview = try editor.preview(edits)
        XCTAssertEqual(editor.arrangement, initial)
        XCTAssertFalse(editor.canUndo)
        try editor.apply(edits)
        XCTAssertEqual(editor.arrangement, preview)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.arrangement, initial)
        XCTAssertTrue(editor.redo())
        XCTAssertEqual(editor.arrangement, preview)
    }

    func testFailureNoOpAndPreviewPreserveStateAndRedoThenRealEditClearsRedo() throws {
        let initial = try PatternArrangement(regions: [region()])
        var editor = PatternEditor(initial)
        try editor.apply([.delete(id: "a")])
        XCTAssertTrue(editor.undo())
        let failures: [[PatternEdit]] = [
            [.delete(id: "a"), .delete(id: "missing")],
            [.barCount(0)], [.barCount(9)],
            [.setStroke(id: "a", slot: -1, content: try content(3), newStrokeID: nil)],
            [.removeStroke(id: "a", slot: 8)],
            [.setStroke(id: "a", slot: 1, content: try content(3), newStrokeID: nil)],
            [.setStroke(id: "a", slot: 1, content: try content(3), newStrokeID: "")],
            [.setStroke(id: "a", slot: 0, content: try content(3), newStrokeID: "replacement")],
            [.setStroke(id: "a", slot: 1, content: try content(3), newStrokeID: "a-0")],
            [.add(try region("overlap"))]
        ]
        for edits in failures {
            XCTAssertThrowsError(try editor.preview(edits))
            XCTAssertThrowsError(try editor.apply(edits))
            XCTAssertEqual(editor.arrangement, initial)
            XCTAssertFalse(editor.canUndo)
            XCTAssertTrue(editor.canRedo)
        }
        let noOps: [[PatternEdit]] = [[], [.removeStroke(id: "a", slot: 1)],
            [.settings(id: "a", initial.regions[0].settings)],
            [.resize(id: "a", range: initial.regions[0].range)], [.barCount(8)],
            [.setStroke(id: "a", slot: 0, content: try content(8), newStrokeID: nil)],
            [.delete(id: "a"), .add(initial.regions[0])]]
        for edits in noOps {
            try editor.apply(edits)
            XCTAssertEqual(editor.arrangement, initial)
            XCTAssertFalse(editor.canUndo)
            XCTAssertTrue(editor.canRedo)
        }
        _ = try editor.preview([.delete(id: "a")])
        XCTAssertTrue(editor.canRedo)
        XCTAssertTrue(editor.redo())
        XCTAssertEqual(editor.arrangement.regions, [])
        XCTAssertTrue(editor.undo())
        try editor.apply([.removeStroke(id: "a", slot: 0)])
        XCTAssertFalse(editor.canRedo)
    }

    func testDuplicateRequiresFreshRegionAndAllOccupiedStrokeIDs() throws {
        let initial = try PatternArrangement(regions: [region(), region("b", start: 1)])
        var editor = PatternEditor(initial)
        let range = try PatternBarRange(start: 2, length: 1)
        let fresh = (0..<6).map { "fresh-\($0)" }
        let bad: [(String, [String])] = [
            ("a", fresh), ("b", fresh), ("", fresh), ("c", []),
            ("c", Array(fresh.dropLast())), ("c", fresh + ["extra"]),
            ("c", Array(repeating: "same", count: 6)),
            ("c", ["", "1", "2", "3", "4", "5"]),
            ("c", ["a-0"] + Array(fresh.dropFirst())),
            ("c", ["b-0"] + Array(fresh.dropFirst()))
        ]
        for (id, ids) in bad {
            XCTAssertThrowsError(try editor.apply([.duplicate(id: "a", newID: id, range: range,
                occupiedStrokeIDs: ids)]))
            XCTAssertEqual(editor.arrangement, initial)
            XCTAssertFalse(editor.canUndo)
        }
        XCTAssertThrowsError(try editor.apply([
            .duplicate(id: "a", newID: "c", range: range, occupiedStrokeIDs: (0..<6).map { "a-\($0)" }),
            .delete(id: "a")])) // duplication never steals source IDs
        try editor.apply([.duplicate(id: "a", newID: "c", range: range, occupiedStrokeIDs: fresh)])
        XCTAssertEqual(editor.arrangement.regions[2].slots.compactMap { $0?.id }, fresh)
        XCTAssertEqual(editor.arrangement.regions[0], initial.regions[0])
        XCTAssertEqual(editor.arrangement.regions[1], initial.regions[1])
    }

    func testContinuousChuckEditRetainsIDAndEmptyPatternIsNotAbsentRegion() throws {
        var editor = PatternEditor(try PatternArrangement(regions: [region()]))
        for size in [Double.leastNonzeroMagnitude, 0.371, 1] {
            try editor.apply([.setStroke(id: "a", slot: 0, content: .chuck(ChuckSize(size)), newStrokeID: nil)])
            XCTAssertEqual(editor.arrangement.regions[0].slots[0]?.id, "a-0")
            XCTAssertEqual(editor.arrangement.regions[0].slots[0]?.baseVelocity, size)
        }
        try editor.apply((0..<8).map { .removeStroke(id: "a", slot: $0) })
        XCTAssertEqual(editor.arrangement.regions.count, 1)
        XCTAssertTrue(editor.arrangement.regions[0].slots.allSatisfy { $0 == nil })
        XCTAssertNotEqual(editor.arrangement, try PatternArrangement())
        try editor.apply([.setStroke(id: "a", slot: 7, content: try content(10), newStrokeID: "fresh")])
        XCTAssertEqual(editor.arrangement.regions[0].slots[7]?.id, "fresh")
    }

    func testFinalOverlapOutOfBoundsCrossRegionIDsAndMissingTargetsRejectAtomically() throws {
        let initial = try PatternArrangement(barCount: 2, regions: [region(), region("b", start: 1)])
        var editor = PatternEditor(initial)
        try editor.apply([.delete(id: "b")])
        XCTAssertTrue(editor.undo())
        let failures: [[PatternEdit]] = [
            [.resize(id: "a", range: try PatternBarRange(start: 0, length: 2))],
            [.resize(id: "b", range: try PatternBarRange(start: 2, length: 1))],
            [.barCount(1)], [.add(initial.regions[0])],
            [.setStroke(id: "a", slot: 1, content: try content(3), newStrokeID: "b-0")],
            [.resize(id: "missing", range: initial.regions[0].range)],
            [.settings(id: "missing", try PatternSettings())],
            [.setStroke(id: "missing", slot: 0, content: try content(3), newStrokeID: nil)],
            [.removeStroke(id: "missing", slot: 0)],
            [.duplicate(id: "missing", newID: "c", range: initial.regions[0].range, occupiedStrokeIDs: [])],
            [.removeStroke(id: "a", slot: Int.min)],
            [.setStroke(id: "a", slot: Int.max, content: try content(3), newStrokeID: nil)]
        ]
        for edits in failures {
            XCTAssertThrowsError(try editor.apply(edits))
            XCTAssertEqual(editor.arrangement, initial)
            XCTAssertFalse(editor.canUndo)
            XCTAssertTrue(editor.canRedo)
        }
        XCTAssertTrue(editor.redo())
        XCTAssertEqual(editor.arrangement.regions.map(\.id), ["a"])
    }
}
