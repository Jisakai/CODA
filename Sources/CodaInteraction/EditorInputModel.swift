import Foundation

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
public enum RadialRing: Equatable, Sendable { case inner, outer, major, minor, odd, roots }

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

public enum RadialGeometry {
    public static func ring(forRadius radius: Double,
                            rings: [(RadialRing, Double, Double)]) -> RadialRing? {
        guard radius.isFinite, radius > 0 else { return nil }
        return rings.first(where: { radius >= $0.1 && radius <= $0.2 })?.0
    }

    /// Slot zero starts at twelve o'clock; increasing slots advance clockwise.
    public static func slot(atAngle angle: Double, count: Int) -> Int {
        guard angle.isFinite, count > 0 else { return 0 }
        let turn = (angle + .pi / 2 + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        let position = turn / (2 * .pi) * Double(count)
        let boundary = position.rounded()
        // Inverse angle arithmetic can put an exact boundary a few ULPs below
        // its slot. Snap only round-off noise, preserving either side of a hit.
        let stablePosition = abs(position - boundary) <= 4 * Double(count).ulp ? boundary : position
        return min(count - 1, Int(floor(stablePosition)))
    }

    public static func angle(forSlot slot: Int, count: Int) -> Double {
        guard count > 0 else { return -.pi / 2 }
        return Double(slot) * (2 * .pi / Double(count)) - .pi / 2
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
