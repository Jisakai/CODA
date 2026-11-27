import Foundation

/// Provisional Pencil feel values. No pressure, tilt, music-model or UI dependency.
public enum PatternGestureDefaults {
    public static let tapSlop = 5.0
    public static let sampleSpacing = 1.0
    public static let maximumSamples = 1024
    public static let minimumCircleDiameter = 24.0
    public static let closureFraction = 0.28
    public static let minimumAspect = 0.55
    public static let minimumPerimeterRatio = 2.5
    public static let maximumPerimeterRatio = 4.2
    public static let maximumRadialDeviation = 0.32
    public static let minimumTurn = 1.5 * Double.pi
    public static let maximumTurn = 2.6 * Double.pi
    public static let minimumTurnConsistency = 0.85
}

public struct PatternStrokeTarget: Equatable, Sendable {
    public let bar: Int
    public let slot: Int
    public init(bar: Int, slot: Int) { self.bar = bar; self.slot = slot }
}

public struct PatternGestureValue: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case remove
        case arrow(down: Bool, level: Int)
        case chuck(size: Double)
    }
    public let bar: Int
    public let slot: Int
    public let content: Content
}

/// Coordinates are absolute in the same viewport as `frame`; time mapping uses
/// the timeline transform, including zoom and scroll. Only finish can commit.
public struct PatternGestureInterpreter: Sendable {
    private struct Draft: Sendable {
        let frame: CGRect
        let bar: Int
        let slot: Int
        let existing: Bool
        var points: [CGPoint]
    }
    private var draft: Draft?
    public init() {}
    public var isActive: Bool { draft != nil }

    public mutating func begin(at point: CGPoint, device: EditorInputDevice,
                               frame: CGRect, viewport: EditorViewport,
                               existing: PatternStrokeTarget?) {
        cancel()
        guard device == .pencil, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0, finite(point), contains(point, in: frame) else { return }
        let step = viewport.step(atX: Double(point.x - frame.minX), in: Double(frame.width))
        guard existing != nil || step != nil else { return }
        draft = Draft(frame: frame, bar: existing?.bar ?? (step! / 16),
                      slot: existing?.slot ?? ((step! % 16) / 2),
                      existing: existing != nil, points: [point])
    }

    public mutating func move(to point: CGPoint) {
        guard var value = draft else { return }
        guard finite(point), contains(point, in: value.frame) else { cancel(); return }
        guard let last = value.points.last,
              hypot(point.x - last.x, point.y - last.y) >= PatternGestureDefaults.sampleSpacing else { return }
        guard value.points.count < PatternGestureDefaults.maximumSamples else { cancel(); return }
        value.points.append(point)
        draft = value
    }

    public var preview: PatternGestureValue? { interpreted(finishing: false) }
    public mutating func finish(at point: CGPoint) -> PatternGestureValue? {
        move(to: point)
        defer { cancel() }
        return interpreted(finishing: true)
    }
    public mutating func cancel() { draft = nil }

    private func contains(_ point: CGPoint, in frame: CGRect) -> Bool {
        point.x >= frame.minX && point.x < frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
    }
    private func finite(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }
    private func interpreted(finishing: Bool) -> PatternGestureValue? {
        guard let value = draft, let start = value.points.first, let end = value.points.last else { return nil }
        let excursion = value.points.map { hypot($0.x - start.x, $0.y - start.y) }.max() ?? 0
        let content: PatternGestureValue.Content
        if excursion <= PatternGestureDefaults.tapSlop {
            guard finishing, value.existing else { return nil }
            content = .remove
        } else if let size = circleSize(value.points, height: value.frame.height) {
            content = .chuck(size: size)
        } else {
            let length = min(1, abs(Double(end.y - start.y) / Double(value.frame.height)))
            guard length > 0 else { return nil }
            let level = max(1, Int((length * 10).rounded(.toNearestOrAwayFromZero)))
            content = .arrow(down: start.y < value.frame.midY, level: level)
        }
        return PatternGestureValue(bar: value.bar, slot: value.slot, content: content)
    }

    private func circleSize(_ points: [CGPoint], height: CGFloat) -> Double? {
        guard points.count >= 12, let first = points.first, let last = points.last else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let width = xs.max()! - xs.min()!, h = ys.max()! - ys.min()!
        let diameter = max(width, h)
        guard min(width, h) >= PatternGestureDefaults.minimumCircleDiameter,
              min(width, h) / diameter >= PatternGestureDefaults.minimumAspect,
              hypot(last.x - first.x, last.y - first.y) <= diameter * PatternGestureDefaults.closureFraction else { return nil }
        let center = CGPoint(x: (xs.max()! + xs.min()!) / 2, y: (ys.max()! + ys.min()!) / 2)
        let radii = points.map { hypot($0.x - center.x, $0.y - center.y) }
        let mean = radii.reduce(0, +) / Double(radii.count)
        guard mean > 0, radii.allSatisfy({ abs($0 - mean) / mean <= PatternGestureDefaults.maximumRadialDeviation }) else { return nil }
        var path = 0.0, turn = 0.0, absoluteTurn = 0.0
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            path += hypot(b.x - a.x, b.y - a.y)
            var angle = atan2(b.y - center.y, b.x - center.x) - atan2(a.y - center.y, a.x - center.x)
            if angle > .pi { angle -= 2 * .pi }
            if angle < -.pi { angle += 2 * .pi }
            turn += angle; absoluteTurn += abs(angle)
        }
        guard path / diameter >= PatternGestureDefaults.minimumPerimeterRatio,
              path / diameter <= PatternGestureDefaults.maximumPerimeterRatio,
              abs(turn) >= PatternGestureDefaults.minimumTurn,
              absoluteTurn <= PatternGestureDefaults.maximumTurn,
              abs(turn) / max(absoluteTurn, 0.001) >= PatternGestureDefaults.minimumTurnConsistency else { return nil }
        return min(1, Double(diameter / height))
    }
}

/// Shared renderer and hit-test geometry in absolute viewport coordinates.
public struct PatternStrokeGeometry: Sendable {
    public let start: CGPoint
    public let end: CGPoint
    public let head: [CGPoint]
    public let radius: CGFloat?
    public init(x: CGFloat, frame: CGRect, down: Bool, fraction: Double, chuck: Bool = false) {
        let length = frame.height * min(1, max(0, fraction))
        start = CGPoint(x: x, y: chuck ? frame.midY : (down ? frame.minY : frame.maxY))
        end = CGPoint(x: x, y: chuck ? frame.midY : start.y + (down ? length : -length))
        radius = chuck ? max(1, length / 2) : nil
        let h = min(7, length)
        head = chuck ? [] : [end, CGPoint(x: x - 4, y: end.y + (down ? -h : h)),
                                       CGPoint(x: x + 4, y: end.y + (down ? -h : h))]
    }
    public func contains(_ point: CGPoint) -> Bool {
        let tolerance = 6.0
        func segment(_ a: CGPoint, _ b: CGPoint) -> Bool {
            let dx = b.x - a.x, dy = b.y - a.y
            let squaredLength = dx * dx + dy * dy
            let t = squaredLength > 0 ? min(1, max(0, ((point.x-a.x)*dx + (point.y-a.y)*dy) / squaredLength)) : 0
            return hypot(point.x-a.x-t*dx, point.y-a.y-t*dy) <= tolerance
        }
        if let radius {
            let dx = point.x - start.x, dy = point.y - start.y
            if abs(hypot(dx, dy) - radius) <= tolerance { return true }
            let inset = radius * 0.65
            return segment(CGPoint(x: start.x-inset, y: start.y-inset), CGPoint(x: start.x+inset, y: start.y+inset))
                || segment(CGPoint(x: start.x-inset, y: start.y+inset), CGPoint(x: start.x+inset, y: start.y-inset))
        }
        if segment(start, end) { return true }
        // The head is filled, rather than an outline or a diamond hit region.
        guard start != end else { return false }
        let crosses = (0..<3).map { i in
            let a = head[i], b = head[(i+1)%3]
            return (b.x-a.x)*(point.y-a.y) - (b.y-a.y)*(point.x-a.x)
        }
        return crosses.allSatisfy { $0 >= 0 } || crosses.allSatisfy { $0 <= 0 }
    }
}
