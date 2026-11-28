import XCTest
import CoreGraphics
import CodaMusic
import CodaInteraction

final class EditorInputModelTests: XCTestCase {
    func testVisibleKeyboardIncludesEverySemitoneAndRejectsOffscreenRows() {
        var viewport = EditorViewport()
        XCTAssertEqual(viewport.visiblePitches(in: 66), [84, 83, 82])
        XCTAssertEqual(viewport.visiblePitches(in: 67), [84, 83, 82, 81])
        XCTAssertEqual(viewport.visiblePitches(in: 0), [])
        XCTAssertEqual(viewport.visiblePitches(in: .infinity), [])
        viewport.pan(horizontalBy: 0, verticalBy: -11, canvasWidth: 1200, canvasHeight: 400)
        let pitches = viewport.visiblePitches(in: 400)
        XCTAssertEqual(pitches.first, 84)
        XCTAssertEqual(viewport.y(forMIDI: 84), -11)
        for pitch in pitches {
            let y = viewport.y(forMIDI: pitch)
            XCTAssertLessThan(y, 400)
            XCTAssertGreaterThan(y + viewport.semitoneHeight, 0)
        }
        viewport.pan(horizontalBy: 0, verticalBy: 100_000, canvasWidth: 1200, canvasHeight: 400)
        XCTAssertEqual(viewport.visiblePitches(in: 400).first, 127)
        viewport.pan(horizontalBy: 0, verticalBy: -100_000, canvasWidth: 1200, canvasHeight: 400)
        XCTAssertEqual(viewport.visiblePitches(in: 400).last, 0)
    }

    func testCountFittedTiltAdaptivePlacementAndBoundedCornerFallback() throws {
        XCTAssertEqual(RadialGeometry.defaultDirection, -2 * .pi / 3, accuracy: 1e-12)
        let size = CGSize(width: 1194, height: 834)
        let layouts = [(132.0, 48.0), (196, 48), (260, 48)].map {
            RadialRingLayout(count: 4, radius: $0.0, thickness: $0.1)
        }
        for x in [400.0, 800] {
            let tip = CGPoint(x: x, y: 450)
            let placement = try XCTUnwrap(RadialGeometry.placement(tip: tip, viewport: size, layouts: layouts))
            XCTAssertEqual(placement.origin, tip)
            XCTAssertEqual(placement.direction, -2 * .pi / 3, accuracy: 1e-12)
            XCTAssertEqual(placement.scale, 1)
            for _ in 0..<20 {
                XCTAssertEqual(RadialGeometry.placement(tip: tip, viewport: size, layouts: layouts), placement)
            }
        }
        for tip in [CGPoint(x: 600, y: 12), CGPoint(x: 600, y: 822),
                    CGPoint(x: 12, y: 417), CGPoint(x: 1182, y: 417),
                    .zero, CGPoint(x: 1194, y: 0), CGPoint(x: 0, y: 834), CGPoint(x: 1194, y: 834)] {
            let placement = try XCTUnwrap(RadialGeometry.placement(tip: tip, viewport: size, layouts: layouts))
            XCTAssertEqual(RadialGeometry.placement(tip: tip, viewport: size, layouts: layouts), placement)
            XCTAssertGreaterThanOrEqual(placement.scale, 0.8)
            XCTAssertLessThanOrEqual(hypot(placement.origin.x - tip.x, placement.origin.y - tip.y), 120)
            let bounds = RadialGeometry.bounds(layouts: layouts, direction: placement.direction, scale: placement.scale)
                .offsetBy(dx: placement.origin.x, dy: placement.origin.y)
            XCTAssertGreaterThanOrEqual(bounds.minX, 8 - 1e-9)
            XCTAssertGreaterThanOrEqual(bounds.minY, 8 - 1e-9)
            XCTAssertLessThanOrEqual(bounds.maxX, size.width - 8 + 1e-9)
            XCTAssertLessThanOrEqual(bounds.maxY, size.height - 8 + 1e-9)
            if tip.x == 600 && tip.y == 12 { XCTAssertGreaterThan(sin(placement.direction), 0) }
            if tip.x == 600 && tip.y == 822 { XCTAssertLessThan(sin(placement.direction), 0) }
            if tip.x == 0 || tip.x == 1194 {
                XCTAssertGreaterThan(cos(placement.direction) * (tip.x == 0 ? 1 : -1), 0)
                XCTAssertGreaterThan(sin(placement.direction) * (tip.y == 0 ? 1 : -1), 0)
            }
            if tip.x == 12 { XCTAssertGreaterThan(cos(placement.direction), 0) }
            if tip.x == 1182 { XCTAssertLessThan(cos(placement.direction), 0) }
        }
    }

    func testTopCenterCirclesUseExactCounterClockwiseDownwardTilt() throws {
        let size = CGSize(width: 1194, height: 834)
        for count in 1...7 {
            let layouts = [RadialRingLayout(count: count, radius: 260, thickness: 48)]
            for y in [0.0, 8, 12] {
                let tip = CGPoint(x: size.width / 2, y: y)
                let placement = try XCTUnwrap(RadialGeometry.placement(tip: tip, viewport: size, layouts: layouts))
                XCTAssertEqual(placement.direction, .pi / 3, accuracy: 1e-12)
                XCTAssertEqual(placement.origin.x, tip.x)
                XCTAssertEqual(placement.scale, 1)
                let bounds = RadialGeometry.bounds(layouts: layouts, direction: placement.direction)
                    .offsetBy(dx: placement.origin.x, dy: placement.origin.y)
                XCTAssertGreaterThanOrEqual(bounds.minX, 8 - 1e-9)
                XCTAssertGreaterThanOrEqual(bounds.minY, -1e-9)
                XCTAssertLessThanOrEqual(bounds.maxX, size.width - 8 + 1e-9)
                XCTAssertLessThanOrEqual(bounds.maxY, size.height - 8 + 1e-9)
                XCTAssertEqual(RadialGeometry.placement(tip: tip, viewport: size, layouts: layouts), placement)
            }
        }
    }

    func testChromeExclusionAcrossEdgesCornersCountsAndEveryBandExtent() throws {
        for size in [CGSize(width: 1194, height: 834), CGSize(width: 1366, height: 1024),
                     CGSize(width: 1376, height: 1032)] {
            let tips = [CGPoint.zero, CGPoint(x: size.width / 2, y: 0),
                CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: 72),
                CGPoint(x: size.width, y: 72), CGPoint(x: 12, y: 88),
                CGPoint(x: 60, y: 92), CGPoint(x: size.width - 10, y: 92),
                CGPoint(x: 0, y: size.height / 2), CGPoint(x: size.width, y: size.height / 2),
                CGPoint(x: 0, y: size.height), CGPoint(x: size.width / 2, y: size.height),
                CGPoint(x: size.width, y: size.height), CGPoint(x: size.width / 2, y: 450)]
            for count in 1...7 {
                for bands in [[(84.0, 40.0), (136, 48)], [(136.0, 40.0)], [(132.0, 48.0), (196, 48), (260, 48)]] {
                    let layouts = bands.map { RadialRingLayout(count: count, radius: $0.0, thickness: $0.1) }
                    for tip in tips {
                        let placement = try XCTUnwrap(RadialGeometry.placement(tip: tip, viewport: size,
                            layouts: layouts, minimumY: 72))
                        XCTAssertEqual(RadialGeometry.placement(tip: tip, viewport: size,
                            layouts: layouts, minimumY: 72), placement)
                        XCTAssertGreaterThanOrEqual(placement.scale, RadialGeometry.minimumScale)
                        XCTAssertLessThanOrEqual(placement.scale, 1)
                        XCTAssertLessThanOrEqual(hypot(placement.origin.x - tip.x, placement.origin.y - tip.y), 180)
                        // Sample complete backing discs swept along the derived
                        // centerline independently of the solver's bounds.
                        for layout in layouts.map({ $0.oriented(placement.direction) }) {
                            for step in 0...24 {
                                let angle = layout.backing.start + layout.sweep * Double(step) / 24
                                for degree in stride(from: 0, to: 360, by: 15) {
                                    let normal = Double(degree) * .pi / 180
                                    let local = CGPoint(x: cos(angle) * layout.radius + cos(normal) * layout.thickness / 2,
                                                        y: sin(angle) * layout.radius + sin(normal) * layout.thickness / 2)
                                    let x = placement.origin.x + local.x * placement.scale
                                    let y = placement.origin.y + local.y * placement.scale
                                    XCTAssertGreaterThanOrEqual(x, -1e-6)
                                    XCTAssertLessThanOrEqual(x, size.width + 1e-6)
                                    XCTAssertGreaterThanOrEqual(y, 72 - 1e-6)
                                    XCTAssertLessThanOrEqual(y, size.height + 1e-6)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testTopCenterChromeFallbackRetainsCanonicalDownwardTiltAndFeasibleTipAnchor() throws {
        let size = CGSize(width: 1194, height: 834)
        for count in 1...7 {
            for radius in [136.0, 260] {
                let layouts = [RadialRingLayout(count: count, radius: radius, thickness: 48)]
                for y in [0.0, 12, 72, 80, 100] {
                    let tip = CGPoint(x: size.width / 2, y: y)
                    let placement = try XCTUnwrap(RadialGeometry.placement(tip: tip, viewport: size,
                        layouts: layouts, minimumY: 72))
                    XCTAssertEqual(placement.origin.x, tip.x, accuracy: 1e-9)
                    if count < 7 || radius == 260 {
                        XCTAssertEqual(placement.direction, .pi / 3, accuracy: 1e-12)
                        XCTAssertEqual(placement.origin.y, max(84, y), accuracy: 1e-9,
                                       "The complete 8-point tip dot also clears chrome")
                    } else {
                        // Seven 40-point circles span past the old short fan;
                        // retain downward orientation while fitting both ends.
                        XCTAssertGreaterThan(sin(placement.direction), 0)
                        let box = RadialGeometry.bounds(layouts: layouts, direction: placement.direction,
                            scale: placement.scale).offsetBy(dx: placement.origin.x, dy: placement.origin.y)
                        XCTAssertGreaterThanOrEqual(box.minY, 80 - 1e-9)
                        XCTAssertLessThanOrEqual(hypot(placement.origin.x - tip.x, placement.origin.y - tip.y), 180)
                    }
                    XCTAssertEqual(placement.scale, 1)
                }
                let tip = CGPoint(x: 600, y: 450)
                let placement = try XCTUnwrap(RadialGeometry.placement(tip: tip, viewport: size,
                    layouts: layouts, minimumY: 72))
                XCTAssertEqual(placement.origin, tip)
                XCTAssertEqual(placement.direction, RadialGeometry.defaultDirection)
            }
        }
    }

    func testInfeasibleCirclesDoNotReturnAnOverlappingPlacement() {
        let layouts = [RadialRingLayout(count: 7, radius: 260, thickness: 48)]
        for size in [CGSize(width: 1194, height: 72), CGSize(width: 100, height: 180)] {
            XCTAssertNil(RadialGeometry.placement(tip: CGPoint(x: 12, y: 88), viewport: size,
                layouts: layouts, minimumY: 72))
        }
        XCTAssertNil(RadialGeometry.placement(tip: .zero, viewport: CGSize(width: 1194, height: 834), layouts: []))
    }

    func testCircleCentersReachableAndOutsideBackingAndRenderedGapsCancel() {
        for direction in [-Double.pi, RadialGeometry.defaultDirection, .pi / 3, -.pi / 3, .pi / 2, 2 * .pi] {
            for count in 1...7 {
                let layout = RadialRingLayout(count: count, radius: 136, thickness: 48, direction: direction)
                for slot in 0..<count {
                    XCTAssertEqual(layout.slot(at: layout.buttonCenter(slot: slot)), slot)
                }
                for offset in [layout.sweep / 2 + 0.3, .pi, -.pi] {
                    let point = CGPoint(x: cos(direction + offset) * 136, y: sin(direction + offset) * 136)
                    XCTAssertNil(layout.slot(at: point))
                }
                XCTAssertNil(layout.slot(at: .zero))
                XCTAssertNil(layout.slot(at: CGPoint(x: Double.nan, y: 0)))
            }
        }
    }

    func testPagingReachesEveryOptionExactlyOnceAndWraps() {
        for total in 1...32 {
            let pages = RadialPage.count(total: total)
            let reached = (0..<pages).flatMap { Array(RadialPage.indices(total: total, page: $0)) }
            XCTAssertEqual(reached, Array(0..<total))
            XCTAssertEqual(RadialPage.indices(total: total, page: pages), RadialPage.indices(total: total, page: 0))
            for page in 0..<pages { XCTAssertLessThanOrEqual(RadialPage.indices(total: total, page: page).count, 3) }
        }
    }

    func testCountFittedBackingHasRoundEndsAndNonselectableGlassRims() {
        for direction in [-Double.pi, RadialGeometry.defaultDirection, .pi / 3, 2 * .pi] {
            for (radius, thickness) in [(84.0, 40.0), (136, 48), (132, 48), (196, 48), (260, 48)] {
                for count in 1...7 {
                    let layout = RadialRingLayout(count: count, radius: radius, thickness: thickness, direction: direction)
                    for slot in 0..<count {
                        let center = layout.buttonCenter(slot: slot)
                        let angle = atan2(center.y, center.x)
                        let rim = CGPoint(x: center.x + cos(angle) * (thickness / 2 - 1),
                                          y: center.y + sin(angle) * (thickness / 2 - 1))
                        XCTAssertTrue(layout.backing.path().contains(rim))
                        XCTAssertNil(layout.slot(at: rim))
                    }
                    let arc = layout.backing
                    for (angle, sign) in [(arc.start, -1.0), (arc.end, 1.0)] {
                        let cap = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
                        func capPoint(outward: Double, radial: Double = 0) -> CGPoint {
                            CGPoint(x: cap.x - sin(angle) * sign * thickness / 2 * outward + cos(angle) * thickness / 2 * radial,
                                    y: cap.y + cos(angle) * sign * thickness / 2 * outward + sin(angle) * thickness / 2 * radial)
                        }
                        XCTAssertTrue(arc.path().contains(capPoint(outward: 0.95)))
                        XCTAssertFalse(arc.path().contains(capPoint(outward: 1.05)))
                        XCTAssertFalse(arc.path().contains(capPoint(outward: 0.85, radial: 0.85)),
                                       "Backing endpoints must be round")
                    }
                }
            }
        }
    }

    func testMixedVisibleCountsFitCompletePaintedPathsAtPrimaryRootAndAllExtents() throws {
        let size = CGSize(width: 1376, height: 1032)
        for counts in [[1, 4, 7], [7, 4, 1], [2, 3, 4], [1, 1, 1]] {
            let layouts = zip(counts, [132.0, 196, 260]).map {
                RadialRingLayout(count: $0.0, radius: $0.1, thickness: 48)
            }
            for tip in [CGPoint.zero, CGPoint(x: 12, y: 88), CGPoint(x: size.width, y: 0),
                        CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)] {
                let placement = try XCTUnwrap(RadialGeometry.placement(tip: tip, viewport: size, layouts: layouts, minimumY: 72))
                XCTAssertGreaterThanOrEqual(placement.scale, 0.8)
                XCTAssertLessThanOrEqual(hypot(placement.origin.x - tip.x, placement.origin.y - tip.y), 180)
                for layout in layouts.map({ $0.oriented(placement.direction) }) {
                    let paths = [layout.backing.path(center: placement.origin, scale: placement.scale)]
                        + (0..<layout.count).map { layout.buttonPath(slot: $0, center: placement.origin, scale: placement.scale) }
                    for path in paths {
                        let box = path.boundingBoxOfPath
                        XCTAssertGreaterThanOrEqual(box.minX, -1e-6)
                        XCTAssertGreaterThanOrEqual(box.minY, 72 - 1e-6)
                        XCTAssertLessThanOrEqual(box.maxX, size.width + 1e-6)
                        XCTAssertLessThanOrEqual(box.maxY, size.height + 1e-6)
                    }
                }
            }
        }
    }

    func testCountFittedAllChromeCornersRespectDisplacementBeforeScalePreference() throws {
        let size = CGSize(width: 1376, height: 1032)
        for count in 1...7 {
            let layouts = [(132.0, 48.0), (196, 48), (260, 48)].map {
                RadialRingLayout(count: count, radius: $0.0, thickness: $0.1)
            }
            for tip in [CGPoint.zero, CGPoint(x: size.width, y: 0)] {
                let placement = try XCTUnwrap(RadialGeometry.placement(tip: tip, viewport: size,
                    layouts: layouts, minimumY: 72))
                XCTAssertGreaterThanOrEqual(placement.scale, 0.8)
                XCTAssertLessThanOrEqual(placement.scale, 1)
                XCTAssertLessThanOrEqual(hypot(placement.origin.x - tip.x, placement.origin.y - tip.y), 180)
                let box = RadialGeometry.bounds(layouts: layouts, direction: placement.direction, scale: placement.scale)
                    .offsetBy(dx: placement.origin.x, dy: placement.origin.y)
                XCTAssertTrue(CGRect(x: 8, y: 80, width: size.width - 16, height: size.height - 88).contains(box))
            }
            XCTAssertNil(RadialGeometry.placement(tip: CGPoint(x: -1000, y: -1000),
                viewport: size, layouts: layouts, minimumY: 72),
                "No feasible fan may escape the displacement limit")
        }
    }

    func testPopupLayoutAnchorsEachSourceAndFitsTheViewport() {
        let viewport = CGSize(width: 1194, height: 834)
        for x in [10.0, 50, 140, 250, 1150] {
            let anchor = CGRect(x: x, y: 10, width: 32, height: 32)
            let frame = AnchoredPopupLayout.frame(anchor: anchor, size: CGSize(width: 288, height: 300), viewport: viewport)
            XCTAssertTrue(CGRect(origin: .zero, size: viewport).contains(frame))
            XCTAssertEqual(frame.minY, anchor.maxY + 8)
            XCTAssertGreaterThanOrEqual(anchor.midX, frame.minX)
            XCTAssertLessThanOrEqual(anchor.midX, frame.maxX)
        }
        let above = AnchoredPopupLayout.frame(anchor: CGRect(x: 100, y: 810, width: 32, height: 20),
            size: CGSize(width: 288, height: 300), viewport: viewport)
        XCTAssertEqual(above.maxY, 802)
    }

    func testToolIconsKeepStableAccessibleNames() {
        XCTAssertEqual(ChordTool.allCases.map(\.title), ["Swap chord", "Duplicate", "Copy", "Delete", "Paste", "Rest"])
        XCTAssertEqual(Set(ChordTool.allCases.map(\.symbol)).count, ChordTool.allCases.count)
        for tool in ChordTool.allCases { XCTAssertFalse(tool.symbol.isEmpty) }
    }

    func testEmptyChordStartsSnapToBeatGridAndAllowPartialBars() {
        let viewport = EditorViewport()
        let stepWidth = viewport.stepWidth(in: 1280)
        for step in 16..<32 {
            let hit = ChordStripHitTester.hit(x: 56 + (Double(step) + 0.5) * stepWidth,
                y: 50, width: 1336, height: 104, headerWidth: 56, viewport: viewport, regions: [])
            let expectedBeatStart = (step / 4) * 4
            XCTAssertEqual(hit?.target, .emptyBar(startStep: expectedBeatStart))
        }
        let partialHit = ChordStripHitTester.hit(x: 56 + 20.5 * stepWidth,
            y: 50, width: 1336, height: 104, headerWidth: 56, viewport: viewport,
            regions: [(id: "partial", start: 16, end: 18)])
        XCTAssertEqual(partialHit?.target, .emptyBar(startStep: 20),
            "Unused beats in a partial bar are valid chord-start targets")
    }

    func testEveryMusicMutationIsRejectedForFingerAndAcceptedForPencil() {
        let actions: [MusicEditAction] = [
            .add, .select, .audition, .resize, .duplicate, .copy, .paste, .delete,
            .changeRoot, .changeQuality
        ]
        for action in actions {
            XCTAssertFalse(EditorInputRouter.accepts(action, from: .finger), "Finger routed \(action)")
            XCTAssertTrue(EditorInputRouter.accepts(action, from: .pencil), "Pencil blocked \(action)")
        }
    }

    func testOnlyExactFingerMultiTapCountsProduceShortcuts() {
        XCTAssertEqual(FingerShortcutRouter.action(touchCount: 2, tapCount: 2), .undo)
        XCTAssertEqual(FingerShortcutRouter.action(touchCount: 3, tapCount: 2), .redo)
        XCTAssertEqual(FingerShortcutRouter.action(touchCount: 4, tapCount: 1), .toggleChrome)
        for counts in [(2, 1), (3, 1), (4, 2), (1, 2), (5, 1)] {
            XCTAssertNil(FingerShortcutRouter.action(touchCount: counts.0, tapCount: counts.1))
        }
    }

    func testViewportSharesStepAndPitchCoordinatesAtExactEdges() {
        let width = 1310.0
        var viewport = EditorViewport()
        XCTAssertEqual(viewport.step(atX: 0, in: width), 0)
        XCTAssertNil(viewport.step(atX: width, in: width), "Right boundary is exclusive")
        for step in [0, 1, 15, 16, 63, 127] {
            let x = viewport.x(forStep: Double(step) + 0.25, in: width)
            XCTAssertEqual(viewport.step(atX: x, in: width), step)
        }
        XCTAssertEqual(viewport.midi(atY: 0, in: 400), 84)
        XCTAssertEqual(viewport.midi(atY: 21.99, in: 400), 84)
        XCTAssertEqual(viewport.midi(atY: 22, in: 400), 83)
        XCTAssertNil(viewport.midi(atY: 400, in: 400))
    }

    func testZoomKeepsAnchorAndPanClampsBothAxes() {
        let width = 1200.0
        var viewport = EditorViewport()
        let anchor = 440.0
        let before = (anchor + viewport.horizontalOffset) / viewport.stepWidth(in: width)
        viewport.zoom(to: 2, anchoredAtX: anchor, canvasWidth: width)
        let after = (anchor + viewport.horizontalOffset) / viewport.stepWidth(in: width)
        XCTAssertEqual(before, after, accuracy: 1e-9)
        viewport.pan(horizontalBy: -100_000, verticalBy: -100_000,
                     canvasWidth: width, canvasHeight: 500)
        XCTAssertGreaterThan(viewport.horizontalOffset, viewport.maximumHorizontalOffset(width: width))
        XCTAssertEqual(viewport.verticalOffset, Double(viewport.topMIDI + 1) * viewport.semitoneHeight - 500)
        XCTAssertEqual(viewport.midi(atY: 499.99, in: 500), 0)
        viewport.pan(horizontalBy: 200_000, verticalBy: 100_000,
                     canvasWidth: width, canvasHeight: 500)
        XCTAssertEqual(viewport.horizontalOffset, 0)
        XCTAssertEqual(viewport.verticalOffset, Double(84 - 127) * viewport.semitoneHeight)
        XCTAssertEqual(viewport.midi(atY: 0, in: 500), 127)
    }

    func testChordStripHitTestingDistinguishesResizeEdgeEmptyBarsAndGutter() {
        let width = 1310.0
        let viewport = EditorViewport()
        let stepWidth = viewport.stepWidth(in: width)
        let regions: [(id: String, start: Int, end: Int)] = [("a", 0, 16), ("b", 32, 40)]

        let nearRight = ChordStripHitTester.hit(x: 56 + stepWidth * 15.5, y: 20, width: 1366,
            height: 104, headerWidth: 56, viewport: viewport, regions: regions)
        XCTAssertEqual(nearRight?.target, .region(id: "a", resizeEdge: true))

        let empty = ChordStripHitTester.hit(x: 56 + stepWidth * 20, y: 50, width: 1366,
            height: 104, headerWidth: 56, viewport: viewport, regions: regions)
        XCTAssertEqual(empty?.target, .emptyBar(startStep: 20))

        let occupied = ChordStripHitTester.hit(x: 56 + stepWidth * 35, y: 40, width: 1366,
            height: 104, headerWidth: 56, viewport: viewport, regions: regions)
        XCTAssertEqual(occupied?.target, .region(id: "b", resizeEdge: false))

        XCTAssertNil(ChordStripHitTester.hit(x: 55, y: 40, width: 1366, height: 104,
            headerWidth: 56, viewport: viewport, regions: regions))
        XCTAssertEqual(ChordStripHitTester.hit(x: 56, y: 40, width: 1366, height: 104,
            headerWidth: 56, viewport: viewport, regions: regions)?.target,
            .region(id: "a", resizeEdge: false))
        XCTAssertNil(ChordStripHitTester.hit(x: 56 + stepWidth * 50, y: 104, width: 1366,
            height: 104, headerWidth: 56, viewport: viewport, regions: regions))
    }

    func testHoldMenuUsesVisibleClampedRowsAndRejectsDividersAndOutside() {
        for origin in [CGPoint(x: 100, y: 100), CGPoint(x: 1360, y: 1020)] {
            let layout = HoldMenuLayout(origin: origin, viewport: CGSize(width: 1366, height: 1024),
                minimumY: 176, width: 224, rowHeight: 40, dividerHeight: 1)
            XCTAssertGreaterThanOrEqual(layout.frame.minY, 176)
            XCTAssertLessThanOrEqual(layout.frame.maxY, 1016)
            XCTAssertLessThanOrEqual(layout.frame.maxX, 1358)
            for index in 0..<3 {
                let y = layout.frame.minY + Double(index * 41)
                XCTAssertEqual(layout.row(at: CGPoint(x: layout.frame.midX, y: y)), index)
                XCTAssertEqual(layout.row(at: CGPoint(x: layout.frame.midX, y: y + 20)), index)
                XCTAssertNil(layout.row(at: CGPoint(x: layout.frame.minX - 0.1, y: y + 20)))
                XCTAssertNil(layout.row(at: CGPoint(x: layout.frame.maxX, y: y + 20)))
                if index < 2 { XCTAssertNil(layout.row(at: CGPoint(x: layout.frame.midX, y: y + 40.5))) }
            }
            XCTAssertNil(layout.row(at: CGPoint(x: layout.frame.midX, y: layout.frame.minY - 0.1)))
            XCTAssertNil(layout.row(at: CGPoint(x: layout.frame.midX, y: layout.frame.maxY)))
        }
    }

    func testRadialActionsKeepSwapAndQualitySelectionSeparateAndDisableUnavailablePaste() {
        XCTAssertEqual(RadialChoiceResolver.resolve(context: .existingChord, ring: .inner,
            slot: 0, suggestionCount: 3, hasClipboard: false), .swapRoot)
        XCTAssertEqual(RadialChoiceResolver.resolve(context: .existingChord, ring: .outer,
            slot: 0, suggestionCount: 3, hasClipboard: false), .suggestion(0))
        XCTAssertEqual(RadialChoiceResolver.resolve(context: .emptyBar, ring: .inner,
            slot: 0, suggestionCount: 3, hasClipboard: false), nil)
        XCTAssertEqual(RadialChoiceResolver.resolve(context: .emptyBar, ring: .inner,
            slot: 0, suggestionCount: 3, hasClipboard: true), .paste)
        XCTAssertEqual(RadialChoiceResolver.resolve(context: .emptyBar, ring: .inner,
            slot: 1, suggestionCount: 3, hasClipboard: false), .rest)

        var draft = RadialSwapDraft(root: 0, qualityID: "minor7")
        draft.chooseRoot(7)
        draft.chooseQuality("dominant7")
        XCTAssertEqual(draft.root, 7)
        XCTAssertEqual(draft.qualityID, "dominant7")
    }

    func testEveryProductionVocabularyQualityIsReachableOnItsFamilyRing() throws {
        let vocabulary = try ChordVocabulary.load(in: Bundle(for: EditorInputModelTests.self))
        var visited = Set<String>()
        for family in ChordFamily.allCases {
            let ring: RadialRing = switch family {
            case .major: .major
            case .minor: .minor
            case .odd: .odd
            }
            let identifiers = vocabulary.ring(family).map(\.id)
            for index in identifiers.indices {
                XCTAssertEqual(RadialChoiceResolver.resolve(context: .existingChord, ring: ring,
                    slot: index, suggestionCount: 3, hasClipboard: false,
                    qualityIDs: identifiers), .changeQuality(identifiers[index]))
                visited.insert(identifiers[index])
            }
        }
        XCTAssertEqual(visited, Set(vocabulary.qualities.map(\.id)))
    }

    func testRadialRingBoundariesAngleSlotsAndCenterDeadZone() {
        XCTAssertNil(RadialGeometry.ring(forRadius: 40, rings: [(.inner, 64, 104)]))
        XCTAssertEqual(RadialGeometry.ring(forRadius: 64, rings: [(.inner, 64, 104)]), .inner)
        XCTAssertEqual(RadialGeometry.ring(forRadius: 104, rings: [(.inner, 64, 104)]), .inner)
        for count in 1...7 {
            let layout = RadialRingLayout(count: count, radius: 84, thickness: 40)
            XCTAssertNil(layout.slot(at: .zero))
            for slot in 0..<count {
                XCTAssertEqual(layout.slot(at: layout.buttonCenter(slot: slot)), slot)
            }
        }
    }

    func testRadialPreviewDraftDoesNotEditProgressionOrHistory() throws {
        let vocabulary = try ChordVocabulary.load(in: Bundle(for: EditorInputModelTests.self))
        let original = try Chord(root: 0, qualityID: "minor7")
        let pitches = try VoiceLeadingSolver().solve([original], vocabulary: vocabulary)[0]
        let region = try ChordRegion(id: "preview", chord: original, start: 0, length: 16, pitches: pitches)
        let progression = try Progression(regions: [region], vocabulary: vocabulary)
        let editor = ProgressionEditor(progression)
        var draft = RadialSwapDraft(root: original.root, qualityID: original.qualityID)
        draft.chooseRoot(7)
        draft.chooseQuality("dominant7")

        XCTAssertEqual(draft.root, 7)
        XCTAssertEqual(draft.qualityID, "dominant7")
        XCTAssertEqual(editor.progression, progression)
        XCTAssertFalse(editor.canUndo)
        XCTAssertFalse(editor.canRedo)
    }

    func testBarrelRollDeadZoneAndFivePercentDetents() {
        var roll = BarrelRollAccumulator(deadZoneDegrees: 12)
        XCTAssertEqual(roll.consume(degrees: 7), 0)
        XCTAssertEqual(roll.consume(degrees: 4), 0)
        XCTAssertEqual(roll.consume(degrees: 5), 4.0 / 360.0, accuracy: 1e-9)
        // The initial dead zone is paid only once, including on reversal.
        XCTAssertEqual(roll.consume(degrees: -20), -20.0 / 360.0, accuracy: 1e-9)
        XCTAssertEqual(RollDetentTracker.crossed(from: 0.04, to: 0.16), 3)
        XCTAssertEqual(RollDetentTracker.crossed(from: 0.96, to: 1), 1)
    }

    func testBarrelRollAccumulatesSignedInitialJitterInEitherDirection() {
        for direction in [-1.0, 1.0] {
            var roll = BarrelRollAccumulator(deadZoneDegrees: 12)
            XCTAssertEqual(roll.consume(degrees: direction * 7), 0)
            XCTAssertEqual(roll.consume(degrees: direction * -4), 0)
            XCTAssertEqual(roll.consume(degrees: direction * 8), 0)
            XCTAssertEqual(roll.consume(degrees: direction * 5), direction * 4 / 360, accuracy: 1e-12)
        }
    }

    func testBarrelRollExactThresholdEngagesTinyFollowUps() {
        for direction in [-1.0, 1.0] {
            var roll = BarrelRollAccumulator(deadZoneDegrees: 12)
            XCTAssertEqual(roll.consume(degrees: direction * 12), 0)
            XCTAssertEqual(roll.consume(degrees: direction * 0.001), direction * 0.001 / 360, accuracy: 1e-12)
            XCTAssertEqual(roll.consume(degrees: direction * -0.0005), direction * -0.0005 / 360, accuracy: 1e-12)
        }
    }

    func testBarrelRollPreservesRepeatedSmallMovementAndReversals() {
        for direction in [-1.0, 1.0] {
            var roll = BarrelRollAccumulator(deadZoneDegrees: 12)
            XCTAssertEqual(roll.consume(degrees: direction * 15), direction * 3 / 360, accuracy: 1e-12)
            for _ in 0..<40 {
                XCTAssertEqual(roll.consume(degrees: direction * 0.5), direction * 0.5 / 360, accuracy: 1e-12)
            }
            XCTAssertEqual(roll.consume(degrees: direction * -1), direction * -1 / 360, accuracy: 1e-12)
            XCTAssertEqual(roll.consume(degrees: direction * -30), direction * -30 / 360, accuracy: 1e-12)
            XCTAssertEqual(roll.consume(degrees: direction * 0.25), direction * 0.25 / 360, accuracy: 1e-12)
        }
    }

    func testBarrelRollNewAccumulatorRearmsInitialDeadZone() {
        var roll = BarrelRollAccumulator(deadZoneDegrees: 12)
        XCTAssertEqual(roll.consume(degrees: 17), 5.0 / 360, accuracy: 1e-12)
        XCTAssertEqual(roll.consume(degrees: 1), 1.0 / 360, accuracy: 1e-12)

        roll = BarrelRollAccumulator(deadZoneDegrees: 12)
        XCTAssertEqual(roll.consume(degrees: 7), 0)
        XCTAssertEqual(roll.consume(degrees: 4), 0)
        XCTAssertEqual(roll.consume(degrees: 2), 1.0 / 360, accuracy: 1e-12)
    }

    func testBarrelRollIgnoresNonfiniteDeltasBeforeAndAfterActivation() {
        var roll = BarrelRollAccumulator(deadZoneDegrees: 12)
        XCTAssertEqual(roll.consume(degrees: 7), 0)
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(roll.consume(degrees: invalid), 0)
        }
        XCTAssertEqual(roll.consume(degrees: 4), 0)
        XCTAssertEqual(roll.consume(degrees: 2), 1.0 / 360, accuracy: 1e-12)
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(roll.consume(degrees: invalid), 0)
            XCTAssertEqual(roll.consume(degrees: 0.25), 0.25 / 360, accuracy: 1e-12)
        }
    }

    func testBarrelRollZeroDeadZonePreservesEveryFiniteDelta() {
        var roll = BarrelRollAccumulator(deadZoneDegrees: 0)
        for delta in [0.0, 0.001, 1, -0.5, 360, -360, 0] {
            XCTAssertEqual(roll.consume(degrees: delta), delta / 360, accuracy: 1e-12)
        }
    }
}
