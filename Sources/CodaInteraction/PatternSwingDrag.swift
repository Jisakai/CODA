/// UI gesture values only. Preview updates never edit the pattern or its history.
public struct PatternSwingDrag: Equatable, Sendable {
    public static let pointsPerFullRange = 120.0

    public let startValue: Double
    public private(set) var preview: Double

    public init(startValue: Double) {
        self.startValue = startValue
        self.preview = startValue
    }

    public mutating func update(verticalTranslation: Double) {
        preview = value(verticalTranslation: verticalTranslation)
    }

    /// Lift is authoritative: its translation may never have reached preview.
    /// Returning nil also prevents an unchanged drag from creating a pattern.
    public func valueToCommit(verticalTranslation: Double) -> Double? {
        let final = value(verticalTranslation: verticalTranslation)
        return final == startValue ? nil : final
    }

    private func value(verticalTranslation: Double) -> Double {
        min(1, max(0, startValue - verticalTranslation / Self.pointsPerFullRange))
    }
}
