import Foundation

/// Deterministic naming of the owner's notes. No predictor or generated notes.
public enum ChordDetector {
    public static func detect(notes: [RollNote], previous: Chord, vocabulary: ChordVocabulary) -> Chord? {
        guard !notes.isEmpty else { return nil }
        let classes = Set(notes.map { $0.pitch % 12 })
        let bass = notes.min { $0.pitch < $1.pitch }!.pitch % 12
        var weights = [Double](repeating: 0, count: 12)
        for note in notes {
            let beat = note.startTick.isMultiple(of: MusicDefaults.ticksPerBeat) ? 2.0 : 1.0
            weights[note.pitch % 12] += beat * Double(note.durationTicks) * Double(note.velocity) / 127
        }
        var best: (chord: Chord, score: Double, order: Int)?
        for (order, quality) in vocabulary.qualities.enumerated() {
            for root in 0..<12 {
                let expected = Set(quality.intervals.map { ($0 + root) % 12 })
                // A separately voiced slash bass is permitted; other unexplained
                // pitch classes make the shape unknown rather than forcing a name.
                guard classes == expected || (classes == expected.union([bass]) && !expected.contains(bass)) else { continue }
                let score = weights[root] + (root == bass ? weights.reduce(0, +) * 0.35 : 0)
                    + (previous.root == root && previous.qualityID == quality.id ? 0.001 : 0)
                guard let chord = try? Chord(root: root, qualityID: quality.id, slashBass: bass == root ? nil : bass) else { continue }
                if best == nil || score > best!.score || (score == best!.score && order < best!.order) {
                    best = (chord, score, order)
                }
            }
        }
        return best?.chord
    }

    public static func toneLabel(pitch: Int, chord: Chord, vocabulary: ChordVocabulary) -> String {
        let interval = (pitch - chord.root % 12 + 120) % 12
        let intervals = (try? vocabulary.quality(chord.qualityID).intervals) ?? []
        if let degree = intervals.first(where: { $0 % 12 == interval }), degree >= 12 {
            return [12: "8", 13: "b9", 14: "9", 15: "#9", 17: "11", 18: "#11", 20: "b13", 21: "13"][degree] ?? "\(degree)"
        }
        return ["Root", "b9", "2", "m3", "3", "4", "b5", "5", "#5", "6", "m7", "Maj7"][interval]
    }
}

public enum ArrangementExtent {
    public static func roundedSteps(through end: Int) throws -> Int {
        guard end > 0 else { throw MusicError.invalidSpan }
        let bars = (end - 1) / MusicDefaults.stepsPerBar + 1
        let (steps, overflow) = bars.multipliedReportingOverflow(by: MusicDefaults.stepsPerBar)
        guard !overflow, steps <= Int.max / MusicDefaults.ticksPerStep else { throw MusicError.timingOverflow }
        return steps
    }
}
