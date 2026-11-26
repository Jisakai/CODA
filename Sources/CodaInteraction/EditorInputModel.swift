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

/// Shared time/pitch transform for the timeline, chord strip, and read-only roll.
public struct EditorViewport: Equatable, Sendable {
    public let totalSteps: Int
    public let topMIDI: Int
    public private(set) var horizontalZoom: Double
    public private(set) var horizontalOffset: Double
    public private(set) var semitoneHeight: Double
    public private(set) var verticalOffset: Double

    public init(totalSteps: Int = 128, topMIDI: Int = 84,
                horizontalZoom: Double = 1, horizontalOffset: Double = 0,
                semitoneHeight: Double = 22, verticalOffset: Double = 0) {
        self.totalSteps = max(1, totalSteps)
        self.topMIDI = topMIDI
        self.horizontalZoom = min(max(horizontalZoom, 1), 8)
        self.horizontalOffset = max(0, horizontalOffset)
        self.semitoneHeight = min(max(semitoneHeight, 14), 36)
        self.verticalOffset = verticalOffset
    }

    public func stepWidth(in width: Double) -> Double {
        max(0, width) * horizontalZoom / Double(totalSteps)
    }

    public func x(forStep step: Double, in width: Double) -> Double {
        step * stepWidth(in: width) - horizontalOffset
    }

    public func step(atX x: Double, in width: Double) -> Int? {
        guard x.isFinite, width.isFinite, width > 0, x >= 0, x < width else { return nil }
        let unit = stepWidth(in: width)
        guard unit > 0 else { return nil }
        let step = Int(floor((x + horizontalOffset) / unit))
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
        horizontalOffset = min(max(0, horizontalOffset - deltaX), maximumHorizontalOffset(width: canvasWidth))
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
        max(0, width * horizontalZoom - width)
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
        let barStart = (step / stepsPerBar) * stepsPerBar
        let barEnd = barStart + stepsPerBar
        guard !regions.contains(where: { $0.start < barEnd && $0.end > barStart }) else { return nil }
        return ChordStripHit(target: .emptyBar(startStep: barStart))
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
                               qualityIDs: [String] = []) -> RadialIntent? {
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
            if slot < 3 && slot < suggestionCount { return .suggestion(slot) }
            return slot == 3 ? .showAll : nil
        case (_, .roots):
            return slot < 12 ? .chooseRoot(slot) : nil
        case (_, .major), (_, .minor), (_, .odd):
            return qualityIDs.indices.contains(slot) ? .changeQuality(qualityIDs[slot]) : nil
        default:
            return nil
        }
    }
}

/// Three readable options plus one navigation slot, on every large band.
public enum RadialPage {
    public static let capacity = 3
    public static func count(total: Int) -> Int { max(1, (total + capacity - 1) / capacity) }
    public static func indices(total: Int, page: Int) -> Range<Int> {
        let start = (max(0, page) % count(total: total)) * capacity
        return start..<min(total, start + capacity)
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

public enum RadialGeometry {
    public static let sweep = 2 * Double.pi / 3
    public static let defaultDirection = -2 * Double.pi / 3 // 30 degrees CCW from up
    private static let downwardDirection = Double.pi / 3 // 30 degrees CCW from down
    public static let slotGap = 0.015
    public static let minimumScale = 0.8
    private static let fittingScales = [1.0, 0.9, minimumScale]

    public static func angle(forSlot slot: Int, count: Int, direction: Double = defaultDirection) -> Double {
        direction - sweep / 2 + Double(slot) * sweep / Double(max(1, count))
    }

    /// The same angular interval and gaps used by RingSlotShape. A point in
    /// the remaining 240 degrees always cancels, including wrapped angles.
    public static func slot(atAngle angle: Double, count: Int,
                            direction: Double = defaultDirection) -> Int? {
        guard angle.isFinite, count > 0 else { return nil }
        let turn = 2 * Double.pi
        let start = direction - sweep / 2
        let relative = ((angle - start).truncatingRemainder(dividingBy: turn) + turn)
            .truncatingRemainder(dividingBy: turn)
        guard relative < sweep else { return nil }
        let width = sweep / Double(count)
        let index = Int(floor(relative / width))
        let within = relative - Double(index) * width
        guard within >= slotGap, within <= width - slotGap else { return nil }
        return index
    }

    /// Exact occupied sector bounds: tip, endpoints, and enclosed cardinal extrema.
    public static func bounds(direction: Double, radius: Double) -> CGRect {
        let start = direction - sweep / 2
        let end = direction + sweep / 2
        var points = [CGPoint.zero,
                      CGPoint(x: cos(start) * radius, y: sin(start) * radius),
                      CGPoint(x: cos(end) * radius, y: sin(end) * radius)]
        for index in -8...8 {
            let angle = Double(index) * .pi / 2
            if angle >= start && angle <= end {
                points.append(CGPoint(x: cos(angle) * radius, y: sin(angle) * radius))
            }
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    public static func placement(tip: CGPoint, viewport: CGSize, outerRadius: Double,
                                 margin: Double = 8) -> RadialPlacement {
        let available = CGRect(origin: .zero, size: viewport).insetBy(dx: margin, dy: margin)
        // At an exact edge, relax only the margin needed to keep the tip anchored.
        // Displaced corner fallbacks still respect the full margin below.
        let anchoredAvailable = CGRect(
            x: min(available.minX, tip.x), y: min(available.minY, tip.y),
            width: max(available.maxX, tip.x) - min(available.minX, tip.x),
            height: max(available.maxY, tip.y) - min(available.minY, tip.y))
        let upwardBounds = bounds(direction: defaultDirection, radius: outerRadius)
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
                let box = bounds(direction: direction, radius: outerRadius * scale)
                    .offsetBy(dx: tip.x, dy: tip.y)
                if anchoredAvailable.contains(box) {
                    return RadialPlacement(origin: tip, direction: direction, scale: scale)
                }
            }
        }
        // A 120-degree fan cannot fit an exact 90-degree viewport corner at its
        // tip. Only then allow bounded scale and the smallest fitting displacement.
        var best = RadialPlacement(origin: tip, direction: preferred)
        var bestCost = Double.infinity
        for scale in fittingScales {
            for direction in directions {
                let box = bounds(direction: direction, radius: outerRadius * scale)
                guard box.width <= available.width, box.height <= available.height else { continue }
                let x = min(available.maxX - box.maxX, max(available.minX - box.minX, tip.x))
                let y = min(available.maxY - box.maxY, max(available.minY - box.minY, tip.y))
                let cost = hypot(x - tip.x, y - tip.y) + (1 - scale) * outerRadius + distance(direction)
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
/// returns normalized knob movement after it is crossed.
public struct BarrelRollAccumulator: Sendable {
    public let deadZoneDegrees: Double
    private var accumulatedDegrees = 0.0

    public init(deadZoneDegrees: Double = 12) {
        self.deadZoneDegrees = max(0, deadZoneDegrees)
    }

    public mutating func consume(degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        accumulatedDegrees += degrees
        guard abs(accumulatedDegrees) >= deadZoneDegrees else { return 0 }
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
