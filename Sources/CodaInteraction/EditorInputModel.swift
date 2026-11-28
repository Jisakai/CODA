import Foundation
import CoreGraphics

public enum EditorInputDevice: Equatable, Sendable {
    case finger
    case pencil
}

public enum MusicEditAction: Equatable, Sendable {
    case add
    case select
    case audition
    case resize
    case duplicate
    case copy
    case paste
    case delete
    case changeRoot
    case changeQuality
}

/// The single policy gate used by the UIKit event ingress before any music action.
public enum EditorInputRouter {
    public static func accepts(_ action: MusicEditAction, from device: EditorInputDevice) -> Bool {
        device == .pencil
    }
}

public enum FingerShortcut: Equatable, Sendable {
    case undo
    case redo
    case toggleChrome
}

public enum FingerShortcutRouter {
    /// Tap count is per finger: two-finger double tap is (2, 2), not (2, 1).
    public static func action(touchCount: Int, tapCount: Int) -> FingerShortcut? {
        switch (touchCount, tapCount) {
        case (2, 2): .undo
        case (3, 2): .redo
        case (4, 1): .toggleChrome
        default: nil
        }
    }
}

/// Shared transform. The initial eight-bar view determines scale, never song
/// length. Increasing the extent preserves every existing canvas coordinate.
public struct EditorViewport: Equatable, Sendable {
    public private(set) var totalSteps: Int
    public let initialVisibleSteps: Int
    public let topMIDI: Int
    public private(set) var horizontalZoom: Double
    public private(set) var horizontalOffset: Double
    public private(set) var semitoneHeight: Double
    public private(set) var verticalOffset: Double

    public init(totalSteps: Int = 128, topMIDI: Int = 84,
                horizontalZoom: Double = 1, horizontalOffset: Double = 0,
                semitoneHeight: Double = 22, verticalOffset: Double = 0) {
        self.totalSteps = max(1, totalSteps)
        self.initialVisibleSteps = min(128, max(1, totalSteps))
        self.topMIDI = topMIDI
        self.horizontalZoom = min(max(horizontalZoom, 1), 8)
        self.horizontalOffset = max(0, horizontalOffset)
        self.semitoneHeight = min(max(semitoneHeight, 14), 36)
        self.verticalOffset = verticalOffset
    }

    public func stepWidth(in width: Double) -> Double {
        max(0, width) * horizontalZoom / Double(initialVisibleSteps)
    }

    public func x(forStep step: Double, in width: Double) -> Double {
        step * stepWidth(in: width) - horizontalOffset
    }

    public func step(atX x: Double, in width: Double) -> Int? {
        guard x.isFinite, width.isFinite, width > 0, x >= 0, x < width else { return nil }
        let unit = stepWidth(in: width)
        guard unit > 0 else { return nil }
        guard let step = Int(exactly: floor((x + horizontalOffset) / unit)) else { return nil }
        return (0..<totalSteps).contains(step) ? step : nil
    }

    public func midi(atY y: Double, in height: Double) -> Int? {
        guard y.isFinite, height.isFinite, height > 0, y >= 0, y < height else { return nil }
        let row = Int(floor((y + verticalOffset) / semitoneHeight))
        let midi = topMIDI - row
        return (0...127).contains(midi) ? midi : nil
    }

    public func y(forMIDI midi: Int) -> Double {
        Double(topMIDI - midi) * semitoneHeight - verticalOffset
    }

    /// Only intersecting rows are rendered, in keyboard order. The container
    /// still clips partial first/last rows to its own local roll bounds.
    public func visiblePitches(in height: Double) -> [Int] {
        guard height.isFinite, height > 0 else { return [] }
        return (0...127).reversed().filter {
            let y = self.y(forMIDI: $0)
            return y < height && y + semitoneHeight > 0
        }
    }

    public mutating func pan(horizontalBy deltaX: Double, verticalBy deltaY: Double,
                             canvasWidth: Double, canvasHeight: Double) {
        guard deltaX.isFinite, deltaY.isFinite else { return }
        horizontalOffset = max(0, horizontalOffset - deltaX)
        let minimum = Double(topMIDI - 127) * semitoneHeight
        let maximum = max(minimum, Double(topMIDI + 1) * semitoneHeight - canvasHeight)
        verticalOffset = min(max(minimum, verticalOffset - deltaY), maximum)
    }

    public mutating func zoom(to zoom: Double, anchoredAtX x: Double,
                              canvasWidth: Double) {
        guard zoom.isFinite, x.isFinite, canvasWidth > 0 else { return }
        let anchorStep = (x + horizontalOffset) / stepWidth(in: canvasWidth)
        horizontalZoom = min(max(zoom, 1), 8)
        horizontalOffset = min(max(0, anchorStep * stepWidth(in: canvasWidth) - x),
                               maximumHorizontalOffset(width: canvasWidth))
    }

    public mutating func setVerticalScale(_ value: Double, anchoredAtY y: Double,
                                          canvasHeight: Double) {
        guard value.isFinite, y.isFinite else { return }
        let anchoredRow = (y + verticalOffset) / semitoneHeight
        semitoneHeight = min(max(value, 14), 36)
        let minimum = Double(topMIDI - 127) * semitoneHeight
        let maximum = max(minimum, Double(topMIDI + 1) * semitoneHeight - canvasHeight)
        verticalOffset = min(max(minimum, anchoredRow * semitoneHeight - y), maximum)
    }

    public func maximumHorizontalOffset(width: Double) -> Double {
        max(0, Double(totalSteps) * stepWidth(in: width) - width)
    }

    public mutating func extend(through steps: Int) {
        totalSteps = max(totalSteps, steps)
    }

    public func visibleSteps(in width: Double) -> Range<Int> {
        let unit = stepWidth(in: width)
        guard width.isFinite, width > 0, unit > 0,
              let first = Int(exactly: floor(horizontalOffset / unit)),
              let last = Int(exactly: ceil((horizontalOffset + width) / unit)), last < Int.max else { return 0..<0 }
        return max(0, min(totalSteps, first))..<max(0, min(totalSteps, last + 1))
    }

    public func visibleBars(in width: Double, stepsPerBar: Int = 16) -> Range<Int> {
        let steps = visibleSteps(in: width)
        guard !steps.isEmpty, stepsPerBar > 0 else { return 0..<0 }
        return steps.lowerBound / stepsPerBar..<(steps.upperBound - 1) / stepsPerBar + 1
    }
}

public struct ChordStripHit: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case region(id: String, resizeEdge: Bool)
        case emptyBar(startStep: Int)
    }
    public let target: Target
}

public enum ChordStripHitTester {
    public static func hit(x: Double, y: Double, width: Double, height: Double,
                           headerWidth: Double, viewport: EditorViewport,
                           regions: [(id: String, start: Int, end: Int)],
                           resizeTolerance: Double = 12,
                           stepsPerBar: Int = 16) -> ChordStripHit? {
        guard y >= 0, y < height, x >= headerWidth, x < width,
              stepsPerBar > 0, width > headerWidth else { return nil }
        let contentX = x - headerWidth
        let contentWidth = width - headerWidth
        guard let step = viewport.step(atX: contentX, in: contentWidth) else { return nil }
        if let region = regions.first(where: { step >= $0.start && step < $0.end }) {
            let rightEdge = viewport.x(forStep: Double(region.end), in: contentWidth)
            let nearEdge = abs(contentX - rightEdge) <= resizeTolerance
            return ChordStripHit(target: .region(id: region.id, resizeEdge: nearEdge))
        }
        // Allow chords to start on any beat/grid subdivision in empty space, not only bar starts.
        let gridUnit = max(1, stepsPerBar / 4) // 4 steps = 1 beat by default
        let snapped = (step / gridUnit) * gridUnit
        let startStep = regions.contains(where: { snapped >= $0.start && snapped < $0.end }) ? step : snapped
        return ChordStripHit(target: .emptyBar(startStep: startStep))
    }
}

/// The rendered menu and Pencil routing share this exact, bounded layout.
public struct HoldMenuLayout: Equatable, Sendable {
    public let frame: CGRect
    public let rowHeight: Double
    public let dividerHeight: Double
    public let rowCount: Int

    public init(origin: CGPoint, viewport: CGSize, minimumY: Double,
                width: Double, rowHeight: Double, dividerHeight: Double,
                rowCount: Int = 3, margin: Double = 8) {
        self.rowHeight = rowHeight
        self.dividerHeight = dividerHeight
        self.rowCount = rowCount
        let height = Double(rowCount) * rowHeight + Double(max(0, rowCount - 1)) * dividerHeight
        frame = CGRect(x: max(margin, min(origin.x, viewport.width - width - margin)),
                       y: max(minimumY, min(origin.y, viewport.height - height - margin)),
                       width: width, height: height)
    }

    public static func == (lhs: HoldMenuLayout, rhs: HoldMenuLayout) -> Bool {
        lhs.frame.origin.x == rhs.frame.origin.x &&
        lhs.frame.origin.y == rhs.frame.origin.y &&
        lhs.frame.size.width == rhs.frame.size.width &&
        lhs.frame.size.height == rhs.frame.size.height &&
        lhs.rowHeight == rhs.rowHeight &&
        lhs.dividerHeight == rhs.dividerHeight &&
        lhs.rowCount == rhs.rowCount
    }

    public func row(at point: CGPoint) -> Int? {
        guard frame.contains(point) else { return nil }
        let localY = point.y - frame.minY
        let index = Int(floor(localY / (rowHeight + dividerHeight)))
        guard (0..<rowCount).contains(index),
              localY - Double(index) * (rowHeight + dividerHeight) < rowHeight else { return nil }
        return index
    }
}

public enum RadialContext: Equatable, Sendable { case existingChord, emptyBar }
public enum RadialRing: Hashable, Sendable { case inner, outer, major, minor, odd, roots }

public enum RadialIntent: Equatable, Sendable {
    case swapRoot
    case duplicate
    case copy
    case delete
    case paste
    case rest
    case suggestion(Int)
    case showAll
    case changeQuality(String)
    case chooseRoot(Int)
    case nextPage(RadialRing)
}

/// Visible tool glyphs and spoken names share stable identities. This is only
/// presentation metadata; input authorization remains at the Pencil ingress.
public enum ChordTool: String, CaseIterable, Sendable {
    case swap, duplicate, copy, delete, paste, rest

    public var title: String {
        switch self {
        case .swap: "Swap chord"
        case .duplicate: "Duplicate"
        case .copy: "Copy"
        case .delete: "Delete"
        case .paste: "Paste"
        case .rest: "Rest"
        }
    }

    public var symbol: String {
        switch self {
        case .swap: "arrow.left.arrow.right.circle.fill"
        case .duplicate: "plus.square.fill.on.square.fill"
        case .copy: "doc.on.doc.fill"
        case .delete: "trash.fill"
        case .paste: "clipboard.fill"
        case .rest: "pause.circle.fill"
        }
    }
}

public enum RadialChoiceResolver {
    public static func resolve(context: RadialContext, ring: RadialRing, slot: Int,
                               suggestionCount: Int, hasClipboard: Bool,
                               qualityIDs: [String] = [],
                               allSlotIndex: Int = 3) -> RadialIntent? {
        guard slot >= 0 else { return nil }
        switch (context, ring) {
        case (.existingChord, .inner):
            return switch slot {
            case 0: .swapRoot
            case 1: .duplicate
            case 2: .copy
            case 3: .delete
            default: nil
            }
        case (.emptyBar, .inner):
            return switch slot {
            case 0: hasClipboard ? .paste : nil
            case 1: .rest
            default: nil
            }
        case (_, .outer):
            if slot == allSlotIndex { return .showAll }
            return slot < allSlotIndex && slot < suggestionCount ? .suggestion(slot) : nil
        case (_, .roots):
            return slot < 12 ? .chooseRoot(slot) : nil
        case (_, .major), (_, .minor), (_, .odd):
            return qualityIDs.indices.contains(slot) ? .changeQuality(qualityIDs[slot]) : nil
        default:
            return nil
        }
    }
}

/// Paging helper for radial bands; default capacity is 3, with per-ring pie-slice overrides.
public enum RadialPage {
    public static let capacity = 3
    public static func count(total: Int, capacity: Int = RadialPage.capacity) -> Int {
        let cap = max(1, capacity)
        return max(1, (total + cap - 1) / cap)
    }
    public static func indices(total: Int, page: Int, capacity: Int = RadialPage.capacity) -> Range<Int> {
        let cap = max(1, capacity)
        let start = (max(0, page) % count(total: total, capacity: cap)) * cap
        return start..<min(total, start + cap)
    }
}

/// Immutable placement shared by rendering and selection for the menu's lifetime.
public struct RadialPlacement: Equatable, Sendable {
    public let origin: CGPoint
    public let direction: Double
    public let scale: Double
    public init(origin: CGPoint, direction: Double, scale: Double = 1) {
        self.origin = origin; self.direction = direction; self.scale = scale
    }
    public func point(radius: Double, angle: Double) -> CGPoint {
        CGPoint(x: origin.x + cos(angle) * radius * scale,
                y: origin.y + sin(angle) * radius * scale)
    }
}

/// Continuous ring backing with round ends. A zero-length centerline is one
/// compact backing circle, used when a ring has exactly one choice.
public struct RadialArc: Equatable, Sendable {
    public let radius: Double
    public let thickness: Double
    public let start: Double
    public let end: Double

    public func path(center: CGPoint = .zero, scale: Double = 1) -> CGPath {
        let outline = CGMutablePath()
        let halfWidth = thickness / 2
        guard radius > halfWidth, thickness > 0, end >= start, scale > 0 else { return outline }
        if end == start {
            return CGPath(ellipseIn: CGRect(
                x: center.x + (cos(start) * radius - halfWidth) * scale,
                y: center.y + (sin(start) * radius - halfWidth) * scale,
                width: thickness * scale, height: thickness * scale), transform: nil)
        }
        // One explicit closed contour, rather than a stroked-centerline result.
        // Both hit testing and SwiftUI receive these same filled arc/cap elements.
        let startCenter = CGPoint(x: cos(start) * radius, y: sin(start) * radius)
        let endCenter = CGPoint(x: cos(end) * radius, y: sin(end) * radius)
        outline.move(to: CGPoint(x: cos(start) * (radius + halfWidth),
                                 y: sin(start) * (radius + halfWidth)))
        outline.addArc(center: .zero, radius: radius + halfWidth,
                       startAngle: start, endAngle: end, clockwise: false)
        outline.addArc(center: endCenter, radius: halfWidth,
                       startAngle: end, endAngle: end + .pi, clockwise: false)
        outline.addArc(center: .zero, radius: radius - halfWidth,
                       startAngle: end, endAngle: start, clockwise: true)
        outline.addArc(center: startCenter, radius: halfWidth,
                       startAngle: start + .pi, endAngle: start + 2 * .pi, clockwise: false)
        outline.closeSubpath()
        // The native parity grid isolates SwiftUI-only misses just inside cap
        // tips. Give its curve consumer shorter cubics without changing the
        // contour: de Casteljau subdivision preserves each original polynomial.
        let subdivided = CGMutablePath()
        var current = CGPoint.zero
        outline.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                current = element.points[0]
                subdivided.move(to: current)
            case .addLineToPoint:
                current = element.points[0]
                subdivided.addLine(to: current)
            case .addCurveToPoint:
                Self.appendCubic(to: subdivided, from: current,
                    control1: element.points[0], control2: element.points[1],
                    end: element.points[2], depth: 3)
                current = element.points[2]
            case .closeSubpath:
                subdivided.closeSubpath()
            case .addQuadCurveToPoint:
                // addArc emits cubic curves; retain any quadratic verbatim.
                subdivided.addQuadCurve(to: element.points[1], control: element.points[0])
                current = element.points[1]
            @unknown default:
                break
            }
        }
        // Bake placement into the canonical filled geometry before bridging.
        var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: center.x, ty: center.y)
        return subdivided.copy(using: &transform)!
    }

    private static func appendCubic(to path: CGMutablePath, from p0: CGPoint,
                                    control1 p1: CGPoint, control2 p2: CGPoint,
                                    end p3: CGPoint, depth: Int) {
        guard depth > 0 else {
            path.addCurve(to: p3, control1: p1, control2: p2)
            return
        }
        func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        let a = midpoint(p0, p1), b = midpoint(p1, p2), c = midpoint(p2, p3)
        let d = midpoint(a, b), e = midpoint(b, c)
        let split = midpoint(d, e)
        appendCubic(to: path, from: p0, control1: a, control2: d, end: split, depth: depth - 1)
        appendCubic(to: path, from: split, control1: e, control2: c, end: p3, depth: depth - 1)
    }
}

/// The canonical visible ring: paths, centers, hit testing and placement all use
/// this count-derived layout. End caps are centered on the first/last buttons.
public struct RadialRingLayout: Equatable, Sendable {
    public let count: Int
    public let radius: Double
    public let thickness: Double
    public let direction: Double

    public init(count: Int, radius: Double, thickness: Double,
                direction: Double = RadialGeometry.defaultDirection) {
        self.count = max(0, count)
        self.radius = radius
        self.thickness = thickness
        self.direction = direction
    }

    public var buttonDiameter: Double { max(0, thickness - 2 * RadialGeometry.buttonInset) }
    public var angularSpacing: Double {
        guard radius > 0 else { return 0 }
        // Chord distance, rather than arc length, preserves the exact visible gap.
        return 2 * asin(min(1, (buttonDiameter + RadialGeometry.buttonGap) / (2 * radius)))
    }
    public var sweep: Double { Double(max(0, count - 1)) * angularSpacing }
    public var backingLength: Double { count > 0 ? radius * sweep + thickness : 0 }
    public var backing: RadialArc {
        RadialArc(radius: radius, thickness: count > 0 ? thickness : 0,
                  start: direction - sweep / 2, end: direction + sweep / 2)
    }

    public func oriented(_ direction: Double) -> Self {
        Self(count: count, radius: radius, thickness: thickness, direction: direction)
    }

    public func buttonCenter(slot: Int, center: CGPoint = .zero, scale: Double = 1) -> CGPoint {
        let angle = backing.start + Double(slot) * angularSpacing
        return CGPoint(x: center.x + cos(angle) * radius * scale,
                       y: center.y + sin(angle) * radius * scale)
    }

    public func buttonPath(slot: Int, center: CGPoint = .zero, scale: Double = 1) -> CGPath {
        guard (0..<count).contains(slot), buttonDiameter > 0, scale > 0 else { return CGMutablePath() }
        let point = buttonCenter(slot: slot)
        let circle = CGPath(ellipseIn: CGRect(x: point.x - buttonDiameter / 2,
            y: point.y - buttonDiameter / 2, width: buttonDiameter, height: buttonDiameter), transform: nil)
        var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: center.x, ty: center.y)
        return circle.copy(using: &transform)!
    }

    public func slot(at point: CGPoint) -> Int? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return (0..<count).first { buttonPath(slot: $0).contains(point) }
    }

    public func paintedBounds(center: CGPoint = .zero, scale: Double = 1) -> CGRect {
        guard count > 0 else { return .null }
        return (0..<count).reduce(backing.path(center: center, scale: scale).boundingBoxOfPath) {
            $0.union(buttonPath(slot: $1, center: center, scale: scale).boundingBoxOfPath)
        }
    }
}

public enum RadialGeometry {
    public static let defaultDirection = -2 * Double.pi / 3 // 30 degrees CCW from up
    private static let downwardDirection = Double.pi / 3 // 30 degrees CCW from down
    public static let buttonInset = 4.0 // retain the established band interior
    // Preserve the established 0.015-radian gap at each side of a choice on the
    // nearest family ring (132 pt), now as one shared linear gap on every ring.
    public static let buttonGap = 2 * 132 * sin(0.015)
    public static let minimumScale = 0.8
    public static let maximumDisplacement = 180.0
    private static let fittingScales = [1.0, 0.9, minimumScale]

    public static func bounds(layouts: [RadialRingLayout], direction: Double, scale: Double = 1) -> CGRect {
        layouts.reduce(CGRect(x: -4, y: -4, width: 8, height: 8)) {
            $0.union($1.oriented(direction).paintedBounds(scale: scale))
        }
    }

    public static func placement(tip: CGPoint, viewport: CGSize, layouts: [RadialRingLayout],
                                 margin: Double = 8, minimumY: Double = 0) -> RadialPlacement? {
        // Chrome is an exclusion, not an edge margin that anchoring may relax.
        guard layouts.contains(where: { $0.count > 0 }),
              viewport.width > 2 * margin, viewport.height > minimumY + 2 * margin else { return nil }
        let outerRadius = layouts.map { $0.radius + $0.thickness / 2 }.max() ?? 0
        let available = CGRect(x: margin, y: minimumY + margin,
            width: viewport.width - 2 * margin, height: viewport.height - minimumY - 2 * margin)
        // At a physical edge, relax only the margin needed to keep an in-viewport
        // tip anchored. The top chrome boundary retains its margin in all paths.
        let anchoredMinX = max(0, min(available.minX, tip.x))
        let anchoredMinY = minimumY > 0 ? available.minY : max(0, min(available.minY, tip.y))
        let anchoredAvailable = CGRect(
            x: anchoredMinX, y: anchoredMinY,
            width: min(viewport.width, max(available.maxX, tip.x)) - anchoredMinX,
            height: min(viewport.height, max(available.maxY, tip.y)) - anchoredMinY)
        let upwardBounds = bounds(layouts: layouts, direction: defaultDirection)
            .offsetBy(dx: tip.x, dy: tip.y)
        let preferred = upwardBounds.minY < anchoredAvailable.minY ? downwardDirection : defaultDirection
        func distance(_ angle: Double) -> Double { abs(atan2(sin(angle - preferred), cos(angle - preferred))) }
        // Fixed CCW tilt in either vertical direction; adapt only when occupied
        // bounds require it. Equal rotations prefer CCW, independent of sort ties.
        // Nothing recomputes this during hover/selection.
        let directions = (-180...180).sorted {
            abs($0) == abs($1) ? $0 < $1 : abs($0) < abs($1)
        }.map { preferred + Double($0) * .pi / 180 }
        for scale in fittingScales {
            for direction in directions {
                let box = bounds(layouts: layouts, direction: direction, scale: scale)
                    .offsetBy(dx: tip.x, dy: tip.y)
                if anchoredAvailable.contains(box) {
                    return RadialPlacement(origin: tip, direction: direction, scale: scale)
                }
            }
        }
        // Corners and tips in the reserved chrome cannot always stay anchored.
        // Only then allow bounded scale and the smallest fitting displacement.
        // No feasible placement means no menu, never an unchecked overlapping fan.
        var best: RadialPlacement?
        var bestCost = Double.infinity
        for scale in fittingScales {
            for direction in directions {
                let box = bounds(layouts: layouts, direction: direction, scale: scale)
                guard box.width <= available.width, box.height <= available.height else { continue }
                let x = min(available.maxX - box.maxX, max(available.minX - box.minX, tip.x))
                let y = min(available.maxY - box.maxY, max(available.minY - box.minY, tip.y))
                let displacement = hypot(x - tip.x, y - tip.y)
                // Feasibility precedes preferences: an unscaled candidate must
                // never beat a smaller fitting menu by exceeding the tip limit.
                guard displacement <= maximumDisplacement else { continue }
                let cost = displacement + (1 - scale) * outerRadius + distance(direction)
                if cost < bestCost {
                    bestCost = cost
                    best = RadialPlacement(origin: CGPoint(x: x, y: y), direction: direction, scale: scale)
                }
            }
        }
        return best
    }

    public static func ring(forRadius radius: Double,
                            rings: [(RadialRing, Double, Double)]) -> RadialRing? {
        guard radius.isFinite, radius > 0 else { return nil }
        return rings.first(where: { radius >= $0.1 && radius <= $0.2 })?.0
    }
}

public enum AnchoredPopupLayout {
    public static func frame(anchor: CGRect, size: CGSize, viewport: CGSize,
                             margin: Double = 8, gap: Double = 8) -> CGRect {
        let width = min(size.width, max(0, viewport.width - margin * 2))
        let height = min(size.height, max(0, viewport.height - margin * 2))
        let x = min(viewport.width - margin - width, max(margin, anchor.midX - width / 2))
        let below = anchor.maxY + gap
        let y = below + height <= viewport.height - margin ? below : max(margin, anchor.minY - gap - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// A pending swap only; choosing roots/qualities never mutates editor history.
public struct RadialSwapDraft: Equatable, Sendable {
    public private(set) var root: Int
    public private(set) var qualityID: String

    public init(root: Int, qualityID: String) {
        self.root = root
        self.qualityID = qualityID
    }

    public mutating func chooseRoot(_ value: Int) {
        guard (0...11).contains(value) else { return }
        root = value
    }

    public mutating func chooseQuality(_ value: String) {
        guard !value.isEmpty else { return }
        qualityID = value
    }
}

/// Barrel roll accumulator. It discards the initial hand-motion dead zone and
/// then returns every subsequent delta as normalized knob movement.
public struct BarrelRollAccumulator: Sendable {
    public let deadZoneDegrees: Double
    private var accumulatedDegrees = 0.0
    private var isEngaged = false

    public init(deadZoneDegrees: Double = 12) {
        self.deadZoneDegrees = max(0, deadZoneDegrees)
    }

    public mutating func consume(degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        if isEngaged { return degrees / 360 }
        accumulatedDegrees += degrees
        guard abs(accumulatedDegrees) >= deadZoneDegrees else { return 0 }
        isEngaged = true
        let direction = accumulatedDegrees >= 0 ? 1.0 : -1.0
        let effective = accumulatedDegrees - direction * deadZoneDegrees
        accumulatedDegrees = 0
        return effective / 360
    }
}

public enum RollDetentTracker {
    public static func crossed(from oldValue: Double, to newValue: Double,
                               spacing: Double = 0.05) -> Int {
        guard oldValue.isFinite, newValue.isFinite, spacing > 0 else { return 0 }
        return abs(Int(floor(newValue / spacing)) - Int(floor(oldValue / spacing)))
    }
}
