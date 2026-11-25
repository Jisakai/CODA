import XCTest
@testable import CodaMusic

final class ProgressionEditorTests: MusicTestCase {
    func testAddResizeSwapDuplicateCopyPasteDeleteAndUndoRedo() throws {
        let v = try vocabulary()
        let empty = try Progression(vocabulary: v)
        var editor = ProgressionEditor(empty)
        try editor.apply([.add(region())], vocabulary: v)
        let added = editor.progression
        try editor.apply([.resize(id: "a", start: 1, length: 8),
                          .swap(id: "a", chord: chord(5, "minor9"))], vocabulary: v)
        let changed = editor.progression
        XCTAssertEqual(changed.regions[0].start, 1)
        XCTAssertEqual(changed.regions[0].length, 8)
        XCTAssertEqual(changed.regions[0].chord, try chord(5, "minor9"))
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.progression, added)
        XCTAssertTrue(editor.redo())
        XCTAssertEqual(editor.progression, changed)
        try editor.apply([.duplicate(id: "a", newID: "b", start: 16)], vocabulary: v)
        let clipboard = try editor.copy(id: "a")
        try editor.apply([.paste(clipboard, newID: "c", start: 40)], vocabulary: v)
        XCTAssertEqual(editor.progression.regions[2].pitches, clipboard.pitches)
        try editor.apply([.delete(id: "a")], vocabulary: v)
        XCTAssertEqual(editor.progression.regions.map(\.id), ["b", "c"])
        for _ in 0..<5 { XCTAssertTrue(editor.undo()) }
        XCTAssertEqual(editor.progression, empty)
        XCTAssertFalse(editor.undo())
        for _ in 0..<5 { XCTAssertTrue(editor.redo()) }
        XCTAssertFalse(editor.redo())
    }

    func testFailedTransactionIsAtomicAndKeepsRedo() throws {
        let v = try vocabulary()
        var editor = ProgressionEditor(try Progression(vocabulary: v))
        try editor.apply([.add(region())], vocabulary: v)
        let first = editor.progression
        try editor.apply([.duplicate(id: "a", newID: "b", start: 16)], vocabulary: v)
        XCTAssertTrue(editor.undo())
        XCTAssertThrowsError(try editor.apply([.delete(id: "a"), .delete(id: "missing")], vocabulary: v))
        XCTAssertEqual(editor.progression, first)
        XCTAssertTrue(editor.canRedo)
        XCTAssertThrowsError(try editor.apply([.duplicate(id: "a", newID: "a", start: 32)], vocabulary: v))
        XCTAssertThrowsError(try editor.apply([.resize(id: "a", start: 127, length: 2)], vocabulary: v))
        XCTAssertEqual(editor.progression, first)
        XCTAssertTrue(editor.redo())
    }

    func testAuditionCopyAndNoOpNeverChangeHistoryAndNewEditClearsRedo() throws {
        let v = try vocabulary()
        var editor = ProgressionEditor(try Progression(regions: [region()], vocabulary: v))
        XCTAssertEqual(try editor.audition(id: "a"), editor.progression.regions[0].pitches)
        _ = try editor.copy(id: "a")
        try editor.apply([], vocabulary: v)
        try editor.apply([.resize(id: "a", start: 0, length: 16)], vocabulary: v)
        XCTAssertFalse(editor.canUndo)
        try editor.apply([.delete(id: "a")], vocabulary: v)
        XCTAssertTrue(editor.undo())
        _ = try editor.audition(id: "a")
        _ = try editor.copy(id: "a")
        XCTAssertTrue(editor.canRedo)
        try editor.apply([.resize(id: "a", start: 0, length: 8)], vocabulary: v)
        XCTAssertFalse(editor.canRedo)
        XCTAssertThrowsError(try editor.audition(id: "missing"))
        XCTAssertThrowsError(try editor.copy(id: "missing"))
    }

    func testBatchMayTemporarilyOverlapButFinalStateMustNotOverlap() throws {
        let v = try vocabulary()
        var editor = ProgressionEditor(try Progression(regions: [region(), region("b", start: 16)], vocabulary: v))
        let before = editor.progression
        XCTAssertThrowsError(try editor.apply([.resize(id: "a", start: 0, length: 20)], vocabulary: v))
        XCTAssertEqual(editor.progression, before)
        try editor.apply([.resize(id: "a", start: 0, length: 20),
                          .resize(id: "b", start: 20, length: 12)], vocabulary: v)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.progression, before)
    }

    func testRootOnlyAndQualityOnlySwapPreserveNeighborsAndUsePreviousVoicing() throws {
        let v = try vocabulary()
        let previous = try region("previous", pitches: [60, 63, 67, 70])
        let following = try region("following", start: 32)
        var editor = ProgressionEditor(try Progression(regions: [previous, region(start: 16), following], vocabulary: v))
        try editor.apply([.swap(id: "a", chord: chord(5))], vocabulary: v)
        XCTAssertEqual(editor.progression.regions[1].chord, try chord(5))
        try editor.apply([.swap(id: "a", chord: chord(5, "minor9"))], vocabulary: v)
        let target = try chord(5, "minor9")
        XCTAssertEqual(editor.progression.regions[1].pitches,
                       try VoiceLeadingSolver().solve([target], vocabulary: v, preceding: previous.pitches)[0])
        XCTAssertEqual(editor.progression.regions[0], previous)
        XCTAssertEqual(editor.progression.regions[2], following)
    }
}
