import Foundation

public enum PatternEdit: Sendable {
    case add(PatternRegion)
    case delete(id: String)
    case resize(id: String, range: PatternBarRange)
    case settings(id: String, PatternSettings)
    /// Existing slots retain their ID; new slots require an explicit ID.
    case setStroke(id: String, slot: Int, content: PatternStroke.Content, newStrokeID: String?)
    case removeStroke(id: String, slot: Int)
    /// IDs are in occupied-slot order, all fresh relative to the candidate.
    case duplicate(id: String, newID: String, range: PatternBarRange, occupiedStrokeIDs: [String])
    case barCount(Int)
}

/// Off-thread value editing only; input-device policy belongs to later UI.
public struct PatternEditor: Sendable {
    public private(set) var arrangement: PatternArrangement
    private var undoStack: [PatternArrangement] = []
    private var redoStack: [PatternArrangement] = []
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public init(_ arrangement: PatternArrangement) { self.arrangement = arrangement }

    /// Validate the FINAL candidate, allowing temporary range overlaps. Reads
    /// and failed/no-op transactions never mutate state or consume redo.
    public func preview(_ edits: [PatternEdit]) throws -> PatternArrangement {
        var regions = arrangement.regions
        var barCount = arrangement.barCount
        for edit in edits {
            func index(_ id: String) throws -> Int {
                guard let i = regions.firstIndex(where: { $0.id == id }) else {
                    throw PatternError.missingRegion(id)
                }
                return i
            }
            func checkedSlot(_ slot: Int) throws {
                guard (0..<PatternDefaults.slotsPerBar).contains(slot) else { throw PatternError.invalidSlot }
            }
            switch edit {
            case .add(let region): regions.append(region)
            case .delete(let id): regions.remove(at: try index(id))
            case .barCount(let count): barCount = count
            case .resize(let id, let range):
                let i = try index(id)
                let old = regions[i]
                regions[i] = try PatternRegion(id: old.id, range: range, slots: old.slots, settings: old.settings)
            case .settings(let id, let settings):
                let i = try index(id)
                let old = regions[i]
                regions[i] = try PatternRegion(id: old.id, range: old.range, slots: old.slots, settings: settings)
            case .setStroke(let id, let slot, let content, let newID):
                let i = try index(id)
                try checkedSlot(slot)
                let old = regions[i]
                let strokeID: String
                if let stroke = old.slots[slot] {
                    guard newID == nil else { throw PatternError.freshStrokeIDsRequired }
                    strokeID = stroke.id
                } else {
                    guard let newID else { throw PatternError.freshStrokeIDsRequired }
                    strokeID = newID
                }
                var slots = old.slots
                slots[slot] = try PatternStroke(id: strokeID, content: content)
                regions[i] = try PatternRegion(id: old.id, range: old.range, slots: slots, settings: old.settings)
            case .removeStroke(let id, let slot):
                let i = try index(id)
                try checkedSlot(slot)
                let old = regions[i]
                var slots = old.slots
                slots[slot] = nil
                regions[i] = try PatternRegion(id: old.id, range: old.range, slots: slots, settings: old.settings)
            case .duplicate(let id, let newID, let range, let ids):
                let old = regions[try index(id)]
                // Check freshness even if a later edit deletes the source.
                guard !regions.contains(where: { $0.id == newID }) else { throw PatternError.duplicateRegionID }
                let used = Set(regions.flatMap { $0.slots.compactMap { $0?.id } })
                guard ids.allSatisfy({ !used.contains($0) }) else { throw PatternError.duplicateStrokeID }
                let preset = try PatternPreset(name: "Duplicate", slots: old.slots.map { $0?.content })
                regions.append(try preset.instantiate(id: newID, range: range,
                                                       occupiedStrokeIDs: ids, settings: old.settings))
            }
        }
        return try PatternArrangement(barCount: barCount, regions: regions)
    }

    public mutating func apply(_ edits: [PatternEdit]) throws {
        let next = try preview(edits)
        guard next != arrangement else { return }
        undoStack.append(arrangement)
        arrangement = next
        redoStack.removeAll()
    }

    @discardableResult public mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(arrangement)
        arrangement = previous
        return true
    }

    @discardableResult public mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(arrangement)
        arrangement = next
        return true
    }
}
