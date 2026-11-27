import XCTest
import Foundation
@testable import CodaInteraction

final class PatternGestureInterpreterTests: XCTestCase {
    private let frame = CGRect(x: 56, y: 180, width: 1280, height: 600)

    func testSharedStrokeGeometryUnderZoomAndScroll() throws {
        for zoom in [1.0, 3.0] {
            let viewport = EditorViewport(horizontalZoom: zoom, horizontalOffset: 80)
            let x = frame.minX + viewport.x(forStep: 19, in: frame.width)
            for down in [true, false] {
                let stroke = PatternStrokeGeometry(x: x, frame: frame, down: down, fraction: 0.3)
                XCTAssertTrue(stroke.contains(stroke.start))
                XCTAssertTrue(stroke.contains(stroke.end))
                XCTAssertTrue(stroke.contains(stroke.head[1]))
                XCTAssertFalse(stroke.contains(CGPoint(x: x, y: down ? frame.maxY : frame.minY)))
                XCTAssertFalse(stroke.contains(CGPoint(x: x + 30, y: stroke.end.y)))
            }
            let chuck = PatternStrokeGeometry(x: x, frame: frame, down: true, fraction: 0.2, chuck: true)
            XCTAssertTrue(chuck.contains(CGPoint(x: x + chuck.radius!, y: frame.midY)))
            XCTAssertTrue(chuck.contains(chuck.start))
            XCTAssertFalse(chuck.contains(CGPoint(x: x, y: frame.minY)))
        }
    }

    func testRenderedRingXAndArrowInkExcludeBlankSpace() throws {
        let chuck = PatternStrokeGeometry(x: 500, frame: frame, down: true, fraction: 0.6, chuck: true)
        let radius = try XCTUnwrap(chuck.radius)
        for i in 0..<16 {
            let angle = Double(i) * .pi / 8
            XCTAssertTrue(chuck.contains(CGPoint(x: 500 + radius * cos(angle), y: frame.midY + radius * sin(angle))))
        }
        for sign in [-1.0, 1.0] {
            XCTAssertTrue(chuck.contains(CGPoint(x: 500 + radius * 0.4, y: frame.midY + sign * radius * 0.4)))
        }
        XCTAssertFalse(chuck.contains(CGPoint(x: 500 + radius * 0.5, y: frame.midY)))
        for down in [true, false] {
            let arrow = PatternStrokeGeometry(x: 500, frame: frame, down: down, fraction: 0.3)
            let headInterior = CGPoint(x: 502, y: arrow.end.y + (down ? -5 : 5))
            XCTAssertTrue(arrow.contains(headInterior))
            XCTAssertTrue(arrow.contains(CGPoint(x: 500, y: (arrow.start.y + arrow.end.y) / 2)))
            XCTAssertFalse(arrow.contains(CGPoint(x: 520, y: arrow.end.y)))
        }
    }

    func testRenderedTargetOwnsTapAndDragOutsideItsColumn() throws {
        let target = PatternStrokeTarget(bar: 2, slot: 3)
        let point = CGPoint(x: 100, y: frame.midY)
        for drag in [false, true] {
            var interpreter = PatternGestureInterpreter()
            interpreter.begin(at: point, device: .pencil, frame: frame, viewport: EditorViewport(), existing: target)
            let end = CGPoint(x: point.x, y: point.y + (drag ? 60 : 0))
            let value = try XCTUnwrap(interpreter.finish(at: end))
            XCTAssertEqual(value.bar, target.bar)
            XCTAssertEqual(value.slot, target.slot)
            XCTAssertEqual(value.content, drag ? .arrow(down: false, level: 1) : .remove)
        }
    }

    func testBothDirectionsAllTenLevelsAndAbsoluteSlots() throws {
        for down in [true, false] {
            for level in 1...10 {
                var interpreter = PatternGestureInterpreter()
                let y = down ? frame.minY : frame.maxY
                let start = CGPoint(x: 56 + 1280 * 19 / 128, y: y)
                interpreter.begin(at: start, device: .pencil, frame: frame, viewport: EditorViewport(), existing: nil)
                let end = CGPoint(x: start.x, y: y + (down ? 1 : -1) * CGFloat(level) * 60)
                interpreter.move(to: end)
                let preview = try XCTUnwrap(interpreter.preview)
                XCTAssertEqual(preview.bar, 1)
                XCTAssertEqual(preview.slot, 1)
                XCTAssertEqual(preview.content, .arrow(down: down, level: level))
                XCTAssertEqual(interpreter.finish(at: end), preview)
                XCTAssertFalse(interpreter.isActive)
            }
        }
    }

    func testEveryEighthSlotAcrossAllEightBars() throws {
        for bar in 0..<8 {
            for slot in 0..<8 {
                var interpreter = PatternGestureInterpreter()
                let x = frame.minX + CGFloat(bar * 8 + slot) * frame.width / 64 + 1
                let start = CGPoint(x: x, y: frame.minY)
                interpreter.begin(at: start, device: .pencil, frame: frame, viewport: EditorViewport(), existing: nil)
                let value = try XCTUnwrap(interpreter.finish(at: CGPoint(x: x, y: frame.minY + 60)))
                XCTAssertEqual(value.bar, bar)
                XCTAssertEqual(value.slot, slot)
            }
        }
    }

    func testViewportZoomAndOffsetMapToTimelineEighths() throws {
        var viewport = EditorViewport()
        viewport.zoom(to: 2, anchoredAtX: 640, canvasWidth: 1280)
        var interpreter = PatternGestureInterpreter()
        let point = CGPoint(x: 56 + 5, y: 200)
        let step = try XCTUnwrap(viewport.step(atX: 5, in: 1280))
        interpreter.begin(at: point, device: .pencil, frame: frame, viewport: viewport, existing: nil)
        let value = try XCTUnwrap(interpreter.finish(at: CGPoint(x: point.x, y: 260)))
        XCTAssertEqual(value.bar, step / 16)
        XCTAssertEqual(value.slot, (step % 16) / 2)
    }

    func testTapRemovalZeroAbsentFingerAndCancellation() {
        var interpreter = PatternGestureInterpreter()
        let point = CGPoint(x: 100, y: 200)
        interpreter.begin(at: point, device: .pencil, frame: frame, viewport: EditorViewport(), existing: nil)
        XCTAssertNil(interpreter.finish(at: point))
        interpreter.begin(at: point, device: .pencil, frame: frame, viewport: EditorViewport(), existing: PatternStrokeTarget(bar: 0, slot: 1))
        XCTAssertNil(interpreter.preview)
        XCTAssertEqual(interpreter.finish(at: point)?.content, .remove)
        interpreter.begin(at: point, device: .finger, frame: frame, viewport: EditorViewport(), existing: PatternStrokeTarget(bar: 0, slot: 1))
        XCTAssertNil(interpreter.finish(at: point))
        interpreter.begin(at: point, device: .pencil, frame: frame, viewport: EditorViewport(), existing: nil)
        interpreter.move(to: CGPoint(x: 100, y: 500))
        interpreter.cancel()
        XCTAssertNil(interpreter.finish(at: CGPoint(x: 100, y: 500)))
        interpreter.begin(at: point, device: .pencil, frame: frame, viewport: EditorViewport(), existing: PatternStrokeTarget(bar: 0, slot: 1))
        interpreter.move(to: CGPoint(x: -1, y: 200))
        XCTAssertNil(interpreter.finish(at: point), "Leaving the editing viewport cancels the entire sequence")
    }

    private func interpret(_ points: [CGPoint]) -> PatternGestureValue.Content? {
        var interpreter = PatternGestureInterpreter()
        interpreter.begin(at: points[0], device: .pencil, frame: frame, viewport: EditorViewport(), existing: nil)
        for point in points.dropFirst() { interpreter.move(to: point) }
        return interpreter.finish(at: points.last!)?.content
    }

    private func circle(radius: Double, turns: Double = 1, count: Int = 65) -> [CGPoint] {
        (0..<count).map { i in
            let angle = Double(i) / Double(count - 1) * 2 * .pi * turns
            return CGPoint(x: 300 + radius * cos(angle), y: 450 + radius * sin(angle))
        }
    }

    func testRoughCircleKeepsContinuousSizeAndRejectsFalsePositives() throws {
        var rough = circle(radius: 37)
        rough[rough.count - 1].y += 3
        guard case .chuck(let size) = try XCTUnwrap(interpret(rough)) else { return XCTFail("Expected closed circle") }
        XCTAssertEqual(size, 74.0 / 600, accuracy: 0.002)
        XCTAssertNotEqual(size, 0.1)
        let paths = [circle(radius: 5), circle(radius: 37, turns: 0.7),
                     circle(radius: 37, turns: 2),
                     (0..<30).map { CGPoint(x: Double(300 + ($0 % 2) * 50), y: Double(300 + $0 * 4)) },
                     [CGPoint(x: 300, y: 300), CGPoint(x: 302, y: 305)],
                     [CGPoint(x: 300, y: 300)]]
        for path in paths {
            if case .chuck = interpret(path) { XCTFail("Rejected path became chuck: \(path)") }
        }
    }
}
