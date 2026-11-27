import XCTest
@testable import CodaInteraction

final class PatternSwingDragTests: XCTestCase {
    func testFinalTranslationWinsAfterZeroOnlyPreview() throws {
        var drag = PatternSwingDrag(startValue: 0)
        drag.update(verticalTranslation: 0)
        XCTAssertEqual(drag.preview, 0)
        XCTAssertEqual(try XCTUnwrap(drag.valueToCommit(verticalTranslation: -16)), 16.0 / 120, accuracy: 0.000001)
        XCTAssertEqual(drag.preview, 0, "The final movement need not have appeared in preview")
    }

    func testFinalEventWithoutPreviewAndReturnToStart() throws {
        var drag = PatternSwingDrag(startValue: 0.25)
        XCTAssertEqual(try XCTUnwrap(drag.valueToCommit(verticalTranslation: -16)), 0.25 + 16.0 / 120, accuracy: 0.000001)
        drag.update(verticalTranslation: -60)
        XCTAssertEqual(drag.preview, 0.75, accuracy: 0.000001)
        XCTAssertNil(drag.valueToCommit(verticalTranslation: 0), "Returning to the baseline creates no history")
    }

    func testUpdatesAndFinalReversalUseRetainedBaseline() throws {
        var drag = PatternSwingDrag(startValue: 0.4)
        for (translation, expected) in [(-24.0, 0.6), (-60.0, 0.9), (12.0, 0.3)] {
            drag.update(verticalTranslation: translation)
            XCTAssertEqual(drag.preview, expected, accuracy: 0.000001)
            XCTAssertEqual(drag.startValue, 0.4)
        }
        XCTAssertEqual(try XCTUnwrap(drag.valueToCommit(verticalTranslation: 24)), 0.2, accuracy: 0.000001)
    }

    func testPreviewAndFinalClampingAndBoundaryNoOps() throws {
        var drag = PatternSwingDrag(startValue: 0.4)
        drag.update(verticalTranslation: -1000)
        XCTAssertEqual(drag.preview, 1)
        XCTAssertEqual(drag.valueToCommit(verticalTranslation: 1000), 0)
        drag.update(verticalTranslation: 1000)
        XCTAssertEqual(drag.preview, 0)
        XCTAssertEqual(drag.valueToCommit(verticalTranslation: -1000), 1)
        XCTAssertNil(PatternSwingDrag(startValue: 0).valueToCommit(verticalTranslation: 16))
        XCTAssertNil(PatternSwingDrag(startValue: 1).valueToCommit(verticalTranslation: -16))
    }
}
