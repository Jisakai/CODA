import Foundation

public enum MusicLayer: String, Codable, Hashable, Sendable, CaseIterable {
    case bass, chords, melody

    public var nativeIndex: UInt8 {
        switch self {
        case .chords: return 0
        case .bass: return 1
        case .melody: return 2
        }
    }
}

public enum BassProvenance: Codable, Hashable, Sendable {
    case chordTone(intervalFromRoot: Int)
    case fixedOffset(semitonesFromRoot: Int)
}

public struct BassNote: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    /// Absolute arrangement tick (480 ticks per quarter note).
    public let startTick: Int
    public let durationTicks: Int
    public let pitch: Int
    public let velocity: Int
    public let slide: Bool
    public let provenance: BassProvenance
    public let userEdited: Bool

    public var endTick: Int { startTick + durationTicks }

    public init(
        id: String = UUID().uuidString,
        startTick: Int,
        durationTicks: Int,
        pitch: Int,
        velocity: Int = 104,
        slide: Bool = false,
        provenance: BassProvenance = .chordTone(intervalFromRoot: 0),
        userEdited: Bool = false
    ) throws {
        guard !id.isEmpty, startTick >= 0, durationTicks > 0,
              startTick <= Int.max - durationTicks else { throw MusicError.invalidSpan }
        guard (0...127).contains(pitch), (1...127).contains(velocity) else { throw MusicError.invalidPitches }
        self.id = id
        self.startTick = startTick
        self.durationTicks = durationTicks
        self.pitch = pitch
        self.velocity = velocity
        self.slide = slide
        self.provenance = provenance
        self.userEdited = userEdited
    }
}

public struct MelodyNote: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    /// Absolute arrangement tick (480 ticks per quarter note).
    public let startTick: Int
    public let durationTicks: Int
    public let pitch: Int
    public let velocity: Int
    public let slide: Bool
    /// Subtle micro-timing offset in ticks (SPEC §10: Pencil roll nudge).
    public let nudgeTicks: Int

    public var endTick: Int { startTick + durationTicks }
    public var effectiveStartTick: Int { max(0, startTick + nudgeTicks) }
    public var effectiveEndTick: Int { effectiveStartTick + durationTicks }

    public init(
        id: String = UUID().uuidString,
        startTick: Int,
        durationTicks: Int,
        pitch: Int,
        velocity: Int = 100,
        slide: Bool = false,
        nudgeTicks: Int = 0
    ) throws {
        guard !id.isEmpty, startTick >= 0, durationTicks > 0,
              startTick <= Int.max - durationTicks else { throw MusicError.invalidSpan }
        guard (0...127).contains(pitch), (1...127).contains(velocity) else { throw MusicError.invalidPitches }
        let (nudged, overflow) = startTick.addingReportingOverflow(nudgeTicks)
        guard !overflow, max(0, nudged) <= Int.max - durationTicks else { throw MusicError.timingOverflow }
        self.id = id
        self.startTick = startTick
        self.durationTicks = durationTicks
        self.pitch = pitch
        self.velocity = velocity
        self.slide = slide
        self.nudgeTicks = nudgeTicks
    }
}

public struct BassTrack: Codable, Equatable, Hashable, Sendable {
    public static let empty = try! BassTrack(notes: [])

    public let notes: [BassNote]

    public init(notes: [BassNote] = []) throws {
        guard Set(notes.map(\.id)).count == notes.count else { throw MusicError.duplicateID }
        for pitch in Set(notes.map(\.pitch)) {
            let ordered = notes.filter { $0.pitch == pitch }.sorted { $0.startTick < $1.startTick }
            guard zip(ordered, ordered.dropFirst()).allSatisfy({ $0.0.endTick <= $0.1.startTick }) else {
                throw MusicError.overlap
            }
        }
        self.notes = notes.sorted {
            if $0.startTick != $1.startTick { return $0.startTick < $1.startTick }
            if $0.pitch != $1.pitch { return $0.pitch < $1.pitch }
            return $0.id < $1.id
        }
    }

    public func adding(_ note: BassNote) throws -> BassTrack {
        try BassTrack(notes: notes + [note])
    }

    public func moving(
        id: String,
        toStartTick startTick: Int,
        pitch: Int? = nil,
        provenance: BassProvenance? = nil,
        userEdited: Bool = true
    ) throws -> BassTrack {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            throw MusicError.missingRegion(id)
        }
        var updated = notes
        let old = updated[index]
        updated[index] = try BassNote(
            id: old.id,
            startTick: startTick,
            durationTicks: old.durationTicks,
            pitch: pitch ?? old.pitch,
            velocity: old.velocity,
            slide: old.slide,
            provenance: provenance ?? old.provenance,
            userEdited: userEdited
        )
        return try BassTrack(notes: updated)
    }

    public func resizing(id: String, durationTicks: Int) throws -> BassTrack {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            throw MusicError.missingRegion(id)
        }
        var updated = notes
        let old = updated[index]
        updated[index] = try BassNote(
            id: old.id,
            startTick: old.startTick,
            durationTicks: durationTicks,
            pitch: old.pitch,
            velocity: old.velocity,
            slide: old.slide,
            provenance: old.provenance,
            userEdited: true
        )
        return try BassTrack(notes: updated)
    }

    public func deleting(id: String) throws -> BassTrack {
        guard notes.contains(where: { $0.id == id }) else { throw MusicError.missingRegion(id) }
        return try BassTrack(notes: notes.filter { $0.id != id })
    }

    public func deleting(ids: Set<String>) throws -> BassTrack {
        for id in ids where !notes.contains(where: { $0.id == id }) {
            throw MusicError.missingRegion(id)
        }
        return try BassTrack(notes: notes.filter { !ids.contains($0.id) })
    }

    public func togglingSlide(id: String) throws -> BassTrack {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            throw MusicError.missingRegion(id)
        }
        var updated = notes
        let old = updated[index]
        updated[index] = try BassNote(
            id: old.id,
            startTick: old.startTick,
            durationTicks: old.durationTicks,
            pitch: old.pitch,
            velocity: old.velocity,
            slide: !old.slide,
            provenance: old.provenance,
            userEdited: true
        )
        return try BassTrack(notes: updated)
    }

    public func transposing(ids: Set<String>? = nil, semitones: Int) throws -> BassTrack {
        if let ids {
            for id in ids where !notes.contains(where: { $0.id == id }) {
                throw MusicError.missingRegion(id)
            }
        }
        let updated = try notes.map { note -> BassNote in
            guard ids == nil || ids!.contains(note.id) else { return note }
            return try BassNote(
                id: note.id,
                startTick: note.startTick,
                durationTicks: note.durationTicks,
                pitch: note.pitch + semitones,
                velocity: note.velocity,
                slide: note.slide,
                provenance: note.provenance,
                userEdited: note.userEdited
            )
        }
        return try BassTrack(notes: updated)
    }

    public func nudging(ids: Set<String>? = nil, deltaTicks: Int) throws -> BassTrack {
        if let ids {
            for id in ids where !notes.contains(where: { $0.id == id }) {
                throw MusicError.missingRegion(id)
            }
        }
        let updated = try notes.map { note -> BassNote in
            guard ids == nil || ids!.contains(note.id) else { return note }
            let (shifted, overflow) = note.startTick.addingReportingOverflow(deltaTicks)
            guard !overflow, shifted >= 0 else { throw MusicError.invalidSpan }
            return try BassNote(
                id: note.id,
                startTick: shifted,
                durationTicks: note.durationTicks,
                pitch: note.pitch,
                velocity: note.velocity,
                slide: note.slide,
                provenance: note.provenance,
                userEdited: true
            )
        }
        return try BassTrack(notes: updated)
    }

    public func slicing(id: String, atTick cutTick: Int, rightID: String = UUID().uuidString) throws -> BassTrack {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            throw MusicError.missingRegion(id)
        }
        let old = notes[index]
        guard cutTick > old.startTick, cutTick < old.endTick else { return self }
        var updated = notes
        updated[index] = try BassNote(
            id: old.id,
            startTick: old.startTick,
            durationTicks: cutTick - old.startTick,
            pitch: old.pitch,
            velocity: old.velocity,
            slide: old.slide,
            provenance: old.provenance,
            userEdited: true
        )
        let right = try BassNote(
            id: rightID,
            startTick: cutTick,
            durationTicks: old.endTick - cutTick,
            pitch: old.pitch,
            velocity: old.velocity,
            slide: old.slide,
            provenance: old.provenance,
            userEdited: true
        )
        updated.append(right)
        return try BassTrack(notes: updated)
    }

    public func copying(ids: Set<String>) -> [BassNote] {
        notes.filter { ids.contains($0.id) }
    }

    public func pasting(
        _ clipboard: [BassNote],
        atTick anchorTick: Int,
        idGenerator: () -> String = { UUID().uuidString }
    ) throws -> BassTrack {
        guard anchorTick >= 0 else { throw MusicError.invalidSpan }
        guard let earliest = clipboard.map(\.startTick).min() else { return self }
        var updated = notes
        for note in clipboard {
            let offset = note.startTick - earliest
            let (target, overflow) = anchorTick.addingReportingOverflow(offset)
            guard !overflow else { throw MusicError.timingOverflow }
            updated.append(try BassNote(
                id: idGenerator(),
                startTick: target,
                durationTicks: note.durationTicks,
                pitch: note.pitch,
                velocity: note.velocity,
                slide: note.slide,
                provenance: note.provenance,
                userEdited: true
            ))
        }
        return try BassTrack(notes: updated)
    }

    public func clearing() -> BassTrack {
        .empty
    }
}

public struct MelodyTrack: Codable, Equatable, Hashable, Sendable {
    public static let empty = try! MelodyTrack(notes: [])

    public let notes: [MelodyNote]

    public init(notes: [MelodyNote] = []) throws {
        guard Set(notes.map(\.id)).count == notes.count else { throw MusicError.duplicateID }
        for pitch in Set(notes.map(\.pitch)) {
            let ordered = notes.filter { $0.pitch == pitch }.sorted { $0.startTick < $1.startTick }
            guard zip(ordered, ordered.dropFirst()).allSatisfy({ $0.0.endTick <= $0.1.startTick }) else {
                throw MusicError.overlap
            }
        }
        self.notes = notes.sorted {
            if $0.startTick != $1.startTick { return $0.startTick < $1.startTick }
            if $0.pitch != $1.pitch { return $0.pitch < $1.pitch }
            return $0.id < $1.id
        }
    }

    public func adding(_ note: MelodyNote) throws -> MelodyTrack {
        try MelodyTrack(notes: notes + [note])
    }

    public func moving(id: String, toStartTick startTick: Int, pitch: Int? = nil) throws -> MelodyTrack {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            throw MusicError.missingRegion(id)
        }
        var updated = notes
        let old = updated[index]
        updated[index] = try MelodyNote(
            id: old.id,
            startTick: startTick,
            durationTicks: old.durationTicks,
            pitch: pitch ?? old.pitch,
            velocity: old.velocity,
            slide: old.slide,
            nudgeTicks: old.nudgeTicks
        )
        return try MelodyTrack(notes: updated)
    }

    public func resizing(id: String, durationTicks: Int) throws -> MelodyTrack {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            throw MusicError.missingRegion(id)
        }
        var updated = notes
        let old = updated[index]
        updated[index] = try MelodyNote(
            id: old.id,
            startTick: old.startTick,
            durationTicks: durationTicks,
            pitch: old.pitch,
            velocity: old.velocity,
            slide: old.slide,
            nudgeTicks: old.nudgeTicks
        )
        return try MelodyTrack(notes: updated)
    }

    public func deleting(id: String) throws -> MelodyTrack {
        guard notes.contains(where: { $0.id == id }) else { throw MusicError.missingRegion(id) }
        return try MelodyTrack(notes: notes.filter { $0.id != id })
    }

    public func deleting(ids: Set<String>) throws -> MelodyTrack {
        for id in ids where !notes.contains(where: { $0.id == id }) {
            throw MusicError.missingRegion(id)
        }
        return try MelodyTrack(notes: notes.filter { !ids.contains($0.id) })
    }

    public func togglingSlide(id: String) throws -> MelodyTrack {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            throw MusicError.missingRegion(id)
        }
        var updated = notes
        let old = updated[index]
        updated[index] = try MelodyNote(
            id: old.id,
            startTick: old.startTick,
            durationTicks: old.durationTicks,
            pitch: old.pitch,
            velocity: old.velocity,
            slide: !old.slide,
            nudgeTicks: old.nudgeTicks
        )
        return try MelodyTrack(notes: updated)
    }

    public func transposing(ids: Set<String>? = nil, semitones: Int) throws -> MelodyTrack {
        if let ids {
            for id in ids where !notes.contains(where: { $0.id == id }) {
                throw MusicError.missingRegion(id)
            }
        }
        let updated = try notes.map { note -> MelodyNote in
            guard ids == nil || ids!.contains(note.id) else { return note }
            return try MelodyNote(
                id: note.id,
                startTick: note.startTick,
                durationTicks: note.durationTicks,
                pitch: note.pitch + semitones,
                velocity: note.velocity,
                slide: note.slide,
                nudgeTicks: note.nudgeTicks
            )
        }
        return try MelodyTrack(notes: updated)
    }

    public func nudging(id: String, nudgeTicks: Int) throws -> MelodyTrack {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            throw MusicError.missingRegion(id)
        }
        var updated = notes
        let old = updated[index]
        updated[index] = try MelodyNote(
            id: old.id,
            startTick: old.startTick,
            durationTicks: old.durationTicks,
            pitch: old.pitch,
            velocity: old.velocity,
            slide: old.slide,
            nudgeTicks: nudgeTicks
        )
        return try MelodyTrack(notes: updated)
    }

    public func nudging(ids: Set<String>? = nil, deltaTicks: Int) throws -> MelodyTrack {
        if let ids {
            for id in ids where !notes.contains(where: { $0.id == id }) {
                throw MusicError.missingRegion(id)
            }
        }
        let updated = try notes.map { note -> MelodyNote in
            guard ids == nil || ids!.contains(note.id) else { return note }
            let (nextNudge, overflow) = note.nudgeTicks.addingReportingOverflow(deltaTicks)
            guard !overflow else { throw MusicError.timingOverflow }
            return try MelodyNote(
                id: note.id,
                startTick: note.startTick,
                durationTicks: note.durationTicks,
                pitch: note.pitch,
                velocity: note.velocity,
                slide: note.slide,
                nudgeTicks: nextNudge
            )
        }
        return try MelodyTrack(notes: updated)
    }

    public func slicing(id: String, atTick cutTick: Int, rightID: String = UUID().uuidString) throws -> MelodyTrack {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            throw MusicError.missingRegion(id)
        }
        let old = notes[index]
        guard cutTick > old.startTick, cutTick < old.endTick else { return self }
        var updated = notes
        updated[index] = try MelodyNote(
            id: old.id,
            startTick: old.startTick,
            durationTicks: cutTick - old.startTick,
            pitch: old.pitch,
            velocity: old.velocity,
            slide: old.slide,
            nudgeTicks: old.nudgeTicks
        )
        let right = try MelodyNote(
            id: rightID,
            startTick: cutTick,
            durationTicks: old.endTick - cutTick,
            pitch: old.pitch,
            velocity: old.velocity,
            slide: old.slide,
            nudgeTicks: 0
        )
        updated.append(right)
        return try MelodyTrack(notes: updated)
    }

    public func copying(ids: Set<String>) -> [MelodyNote] {
        notes.filter { ids.contains($0.id) }
    }

    public func pasting(
        _ clipboard: [MelodyNote],
        atTick anchorTick: Int,
        idGenerator: () -> String = { UUID().uuidString }
    ) throws -> MelodyTrack {
        guard anchorTick >= 0 else { throw MusicError.invalidSpan }
        guard let earliest = clipboard.map(\.startTick).min() else { return self }
        var updated = notes
        for note in clipboard {
            let offset = note.startTick - earliest
            let (target, overflow) = anchorTick.addingReportingOverflow(offset)
            guard !overflow else { throw MusicError.timingOverflow }
            updated.append(try MelodyNote(
                id: idGenerator(),
                startTick: target,
                durationTicks: note.durationTicks,
                pitch: note.pitch,
                velocity: note.velocity,
                slide: note.slide,
                nudgeTicks: note.nudgeTicks
            ))
        }
        return try MelodyTrack(notes: updated)
    }

    public func clearing() -> MelodyTrack {
        .empty
    }
}
