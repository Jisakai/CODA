import Foundation

/// All coordinates here are region-relative ticks. The UI owns previews; only
/// the final reducer result is submitted to the session's transaction history.
public enum ChordRollEditor {
    public static let sliceToleranceTicks = 15

    public static func voicing(_ region: ChordRegion, pitches: [Int], chord: Chord? = nil) throws -> ChordRegion {
        let uniquePitches = Array(Set(pitches)).sorted()
        guard !uniquePitches.isEmpty else { throw MusicError.invalidPitches }
        var notes: [RollNote] = []
        for (rank, pitch) in uniquePitches.enumerated() {
            let sourcePitch = region.pitches[min(rank, region.pitches.count - 1)]
            for note in region.notes where note.pitch == sourcePitch {
                notes.append(try RollNote(id: rank < region.pitches.count ? note.id : UUID().uuidString,
                    startTick: note.startTick, durationTicks: note.durationTicks, pitch: pitch,
                    velocity: note.velocity, slide: note.slide))
            }
        }
        return try ChordRegion(id: region.id, chord: chord ?? region.chord, start: region.start,
            length: region.length, pitches: [], notes: notes)
    }

    public static func replacing(_ region: ChordRegion, notes: [RollNote], vocabulary: ChordVocabulary,
                                 detect: Bool = true) throws -> ChordRegion {
        let chord = detect ? ChordDetector.detect(notes: notes, previous: region.chord, vocabulary: vocabulary) : region.chord
        return try ChordRegion(id: region.id, chord: chord ?? region.chord, start: region.start,
            length: region.length, pitches: [], notes: notes,
            detectionUncertain: detect ? chord == nil : region.detectionUncertain)
    }

    /// Each entry is one note's actual crossing. Partial and staggered cuts are
    /// retained even when no harmonic split is justified.
    public static func slice(_ region: ChordRegion, cuts: [String: Int], vocabulary: ChordVocabulary,
                             rightID: String = UUID().uuidString) throws -> [ChordRegion] {
        var notes: [RollNote] = []
        var validCuts: [String: Int] = [:]
        for note in region.notes {
            guard let cut = cuts[note.id], cut > note.startTick, cut < note.endTick else { notes.append(note); continue }
            validCuts[note.id] = cut
            notes.append(try RollNote(id: note.id, startTick: note.startTick, durationTicks: cut - note.startTick,
                pitch: note.pitch, velocity: note.velocity, slide: note.slide))
            notes.append(try RollNote(startTick: cut, durationTicks: note.endTick - cut,
                pitch: note.pitch, velocity: note.velocity, slide: note.slide))
        }
        guard let first = validCuts.values.sorted().first else { return [region] }
        let splitStep = Int((Double(first) / Double(MusicDefaults.ticksPerStep)).rounded())
        let tick = splitStep * MusicDefaults.ticksPerStep
        let sounding = region.notes.filter { $0.startTick < tick && $0.endTick > tick }
        let synchronized = !sounding.isEmpty && sounding.allSatisfy {
            validCuts[$0.id].map { abs($0 - tick) <= sliceToleranceTicks } ?? false
        }
        guard synchronized, splitStep > 0, splitStep < region.length else {
            return [try replacing(region, notes: notes, vocabulary: vocabulary)]
        }
        // Align only the fully synchronized slice; preserve all preexisting
        // onsets, offsets and independent partial cuts on either side.
        var left: [RollNote] = [], right: [RollNote] = []
        for note in region.notes {
            if note.startTick < tick {
                left.append(try RollNote(id: note.id, startTick: note.startTick,
                    durationTicks: min(tick, note.endTick) - note.startTick,
                    pitch: note.pitch, velocity: note.velocity, slide: note.slide))
            }
            if note.endTick > tick {
                right.append(try RollNote(startTick: max(0, note.startTick - tick),
                    durationTicks: note.endTick - max(tick, note.startTick),
                    pitch: note.pitch, velocity: note.velocity, slide: note.slide))
            }
        }
        let lhs = try ChordRegion(id: region.id, chord: region.chord, start: region.start,
            length: splitStep, pitches: [], notes: left, detectionUncertain: region.detectionUncertain)
        let rhs = try ChordRegion(id: rightID, chord: region.chord, start: region.start + splitStep,
            length: region.length - splitStep, pitches: [], notes: right, detectionUncertain: region.detectionUncertain)
        return [try replacing(lhs, notes: left, vocabulary: vocabulary), try replacing(rhs, notes: right, vocabulary: vocabulary)]
    }
}
