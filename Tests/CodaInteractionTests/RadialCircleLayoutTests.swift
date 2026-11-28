import XCTest
import CoreGraphics
import CodaInteraction

final class RadialCircleLayoutTests: XCTestCase {
    func testOneThroughSevenCirclesUseExactDiametersGapsAndCountFittedBacking() {
        for direction in [-Double.pi, RadialGeometry.defaultDirection, .pi / 3, -.pi / 3, .pi / 2, 2 * .pi] {
            for (radius, thickness) in [(84.0, 40.0), (136, 40), (136, 48), (132, 48), (196, 48), (260, 48)] {
                var previousLength = 0.0
                for count in 1...7 {
                    let layout = RadialRingLayout(count: count, radius: radius, thickness: thickness, direction: direction)
                    let diameter = thickness - 8
                    XCTAssertEqual(layout.buttonDiameter, diameter)
                    XCTAssertGreaterThan(layout.backingLength, previousLength)
                    previousLength = layout.backingLength
                    XCTAssertEqual(layout.backing.end - layout.backing.start,
                                   Double(count - 1) * layout.angularSpacing, accuracy: 1e-12)
                    XCTAssertEqual(layout.backingLength, Double(count - 1) * layout.angularSpacing * radius + thickness,
                                   accuracy: 1e-9)
                    for slot in 0..<count {
                        let center = layout.buttonCenter(slot: slot)
                        let box = layout.buttonPath(slot: slot).boundingBoxOfPath
                        XCTAssertEqual(box.width, diameter, accuracy: 1e-9)
                        XCTAssertEqual(box.height, diameter, accuracy: 1e-9)
                        XCTAssertEqual(box.midX, center.x, accuracy: 1e-9)
                        XCTAssertEqual(box.midY, center.y, accuracy: 1e-9)
                        XCTAssertEqual(layout.slot(at: center), slot)
                        for other in 0..<slot {
                            let neighbor = layout.buttonCenter(slot: other)
                            XCTAssertGreaterThanOrEqual(hypot(center.x - neighbor.x, center.y - neighbor.y),
                                                       diameter + RadialGeometry.buttonGap - 1e-9)
                        }
                        if slot > 0 {
                            let previous = layout.buttonCenter(slot: slot - 1)
                            XCTAssertEqual(hypot(center.x - previous.x, center.y - previous.y) - diameter,
                                           RadialGeometry.buttonGap, accuracy: 1e-9)
                            let gap = CGPoint(x: (center.x + previous.x) / 2, y: (center.y + previous.y) / 2)
                            XCTAssertTrue(layout.backing.path().contains(gap))
                            XCTAssertNil(layout.slot(at: gap), "Backing between circles is never an option")
                        }
                    }
                    for (slot, angle) in [(0, layout.backing.start), (count - 1, layout.backing.end)] {
                        let center = layout.buttonCenter(slot: slot)
                        XCTAssertEqual(center.x, cos(angle) * radius, accuracy: 1e-9)
                        XCTAssertEqual(center.y, sin(angle) * radius, accuracy: 1e-9)
                    }
                    if count == 1 {
                        let box = layout.backing.path().boundingBoxOfPath
                        XCTAssertEqual(box.width, thickness, accuracy: 1e-9)
                        XCTAssertEqual(box.height, thickness, accuracy: 1e-9)
                    }
                }
            }
        }
    }

    func testBoundsUseAllPaintedPathsAtEveryDirectionCountRadiusAndScale() {
        for direction in [-Double.pi, RadialGeometry.defaultDirection, .pi / 3, -.pi / 3, .pi / 2, 2 * .pi] {
            for (radius, thickness) in [(84.0, 40.0), (136, 40), (136, 48), (132, 48), (196, 48), (260, 48)] {
                for count in 1...7 {
                    let layout = RadialRingLayout(count: count, radius: radius, thickness: thickness, direction: direction)
                    for scale in [0.8, 0.9, 1.0] {
                        let center = CGPoint(x: 300, y: 400)
                        let paths = [layout.backing.path(center: center, scale: scale)]
                            + (0..<count).map { layout.buttonPath(slot: $0, center: center, scale: scale) }
                        let painted = paths.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }
                        XCTAssertEqual(layout.paintedBounds(center: center, scale: scale), painted)
                        let menuBounds = RadialGeometry.bounds(layouts: [layout], direction: direction, scale: scale)
                            .offsetBy(dx: center.x, dy: center.y)
                        XCTAssertTrue(menuBounds.insetBy(dx: -1e-9, dy: -1e-9).contains(painted))
                        XCTAssertTrue(menuBounds.contains(CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)))
                    }
                }
            }
        }
    }
}
