import Foundation

/// Deterministic Bass layer follower implementing SPEC §9.
/// Pure value transformations only — never mutates melody or performs UI/audio side effects.
public struct BassFollower: Sendable {
    public static let defaultOctaveWindow: ClosedRange<Int> = 36...55

    public init() {}

    /// Seeds bass notes from a chord progression's roots (or slash bass when present)
    /// into the low octave window with smooth register continuity.
    public static func seedFromProgression(
        _ progression: Progression,
        vocabulary: ChordVocabulary,
        octaveWindow: ClosedRange<Int> = defaultOctaveWindow
    ) -> [BassNote] {
        var result: [BassNote] = []
        var previousPitch: Int?

        for region in progression.regions {
            let startTick = region.start * MusicDefaults.ticksPerStep
            let durationTicks = region.length * MusicDefaults.ticksPerStep
            let bassPC = region.chord.slashBass ?? region.chord.root
            let pitch = resolvePitch(pitchClass: bassPC, near: previousPitch, in: octaveWindow)
            let provenance: BassProvenance
            if let slash = region.chord.slashBass {
                let offset = (slash - region.chord.root + 12) % 12
                let intervals = (try? vocabulary.quality(region.chord.qualityID).intervals) ?? [0]
                if let matched = intervals.first(where: { $0 % 12 == offset }) {
                    provenance = .chordTone(intervalFromRoot: matched)
                } else {
                    provenance = .fixedOffset(semitonesFromRoot: offset)
                }
            } else {
                provenance = .chordTone(intervalFromRoot: 0)
            }

            if let note = try? BassNote(
                id: "bass-\(region.id)",
                startTick: startTick,
                durationTicks: durationTicks,
                pitch: pitch,
                velocity: 104,
                slide: false,
                provenance: provenance,
                userEdited: false
            ) {
                result.append(note)
                previousPitch = pitch
            }
        }
        return result
    }

    /// Re-evaluates provenance when the user drags a bass note to a new pitch/tick (SPEC §9).
    public static func evaluateProvenance(
        pitch: Int,
        atTick tick: Int,
        in regions: [ChordRegion],
        vocabulary: ChordVocabulary
    ) -> BassProvenance {
        guard let region = regionCovering(tick: tick, in: regions) else {
            return .fixedOffset(semitonesFromRoot: (pitch % 12 + 12) % 12)
        }
        let semitonesFromRoot = ((pitch % 12 + 12) % 12 - region.chord.root + 12) % 12
        let intervals = (try? vocabulary.quality(region.chord.qualityID).intervals) ?? []
        if let matched = intervals.first(where: { $0 % 12 == semitonesFromRoot }) {
            return .chordTone(intervalFromRoot: matched)
        }
        return .fixedOffset(semitonesFromRoot: semitonesFromRoot)
    }

    /// Reconciles existing bass notes against updated chord regions (SPEC §9):
    /// - Rhythm (`startTick`, `durationTicks`), `velocity`, `slide`, and `id` are preserved.
    /// - Chord-tone notes follow their chord-tone function (e.g. m3 -> M3 when minor becomes major).
    /// - Non-chord-tone notes keep their fixed semitone offset from the new root.
    /// - Slash-bass is respected for root/slash-following bass notes.
    /// - Resolved into `octaveWindow` avoiding octave jumps relative to the note's prior pitch.
    public static func reconcile(
        bassNotes: [BassNote],
        previousRegions: [ChordRegion],
        newRegions: [ChordRegion],
        vocabulary: ChordVocabulary,
        octaveWindow: ClosedRange<Int> = defaultOctaveWindow
    ) -> [BassNote] {
        bassNotes.map { note in
            guard let newRegion = regionCovering(tick: note.startTick, in: newRegions) else {
                return note
            }
            let prevRegion = regionCovering(tick: note.startTick, in: previousRegions)
            if let prevRegion, prevRegion.chord == newRegion.chord {
                return note
            }

            let newChord = newRegion.chord
            let newIntervals = (try? vocabulary.quality(newChord.qualityID).intervals) ?? [0]

            let targetPC: Int
            let nextProvenance: BassProvenance

            // Slash-bass handling: if the note was tracking the chord's bass (unedited root/slash
            // or previously on the old slash bass), follow the new chord's slash bass when present.
            let wasOnOldSlash = prevRegion?.chord.slashBass.map { ($0 % 12) == ((note.pitch % 12 + 12) % 12) } ?? false
            let isRootTone: Bool
            if case .chordTone(let interval) = note.provenance, interval % 12 == 0 {
                isRootTone = true
            } else {
                isRootTone = false
            }

            if let newSlash = newChord.slashBass, (wasOnOldSlash || (!note.userEdited && isRootTone)) {
                targetPC = newSlash
                let offset = (newSlash - newChord.root + 12) % 12
                if let matched = newIntervals.first(where: { $0 % 12 == offset }) {
                    nextProvenance = .chordTone(intervalFromRoot: matched)
                } else {
                    nextProvenance = .fixedOffset(semitonesFromRoot: offset)
                }
            } else if wasOnOldSlash && newChord.slashBass == nil && !note.userEdited {
                targetPC = newChord.root
                nextProvenance = .chordTone(intervalFromRoot: 0)
            } else {
                switch note.provenance {
                case .chordTone(let oldInterval):
                    let mappedInterval = mapChordToneFunction(oldInterval: oldInterval, to: newIntervals)
                    targetPC = (newChord.root + mappedInterval) % 12
                    nextProvenance = .chordTone(intervalFromRoot: mappedInterval)

                case .fixedOffset(let semitonesFromRoot):
                    let normalized = (semitonesFromRoot % 12 + 12) % 12
                    targetPC = (newChord.root + normalized) % 12
                    nextProvenance = .fixedOffset(semitonesFromRoot: normalized)
                }
            }

            let resolvedPitch = resolvePitch(pitchClass: targetPC, near: note.pitch, in: octaveWindow)
            return (try? BassNote(
                id: note.id,
                startTick: note.startTick,
                durationTicks: note.durationTicks,
                pitch: resolvedPitch,
                velocity: note.velocity,
                slide: note.slide,
                provenance: nextProvenance,
                userEdited: note.userEdited
            )) ?? note
        }
    }

    // MARK: - Internal Helpers

    static func resolvePitch(pitchClass: Int, near referencePitch: Int?, in window: ClosedRange<Int>) -> Int {
        let pc = (pitchClass % 12 + 12) % 12
        let clampedLower = max(0, window.lowerBound)
        let clampedUpper = min(127, max(clampedLower, window.upperBound))
        let candidates = (clampedLower...clampedUpper).filter { $0 % 12 == pc }

        // Anchor default near lower-middle of window so initial roots sit naturally in octave 2 (e.g. C2 = 36).
        let target = referencePitch ?? (clampedLower + 6)
        if let best = candidates.min(by: { a, b in
            let da = abs(a - target)
            let db = abs(b - target)
            return da == db ? a < b : da < db
        }) {
            return best
        }

        // Fallback if caller supplies a sub-octave window that omits `pc`.
        let fallback = (0...127).filter { $0 % 12 == pc }.min { a, b in
            let da = abs(a - target)
            let db = abs(b - target)
            return da == db ? a < b : da < db
        }
        return fallback ?? clampedLower
    }

    private static func regionCovering(tick: Int, in regions: [ChordRegion]) -> ChordRegion? {
        regions.first { region in
            let startTick = region.start * MusicDefaults.ticksPerStep
            let endTick = region.end * MusicDefaults.ticksPerStep
            return tick >= startTick && tick < endTick
        }
    }

    /// Maps an interval's harmonic function (root, 3rd, 5th, 7th, 9th, 11th, 13th)
    /// to the corresponding tone in `newIntervals`.
    private static func mapChordToneFunction(oldInterval: Int, to newIntervals: [Int]) -> Int {
        guard !newIntervals.isEmpty else { return 0 }
        let mod = (oldInterval % 12 + 12) % 12

        // Exact root
        if mod == 0 { return 0 }

        // Functional degree preference lists (ordered from most direct match to nearest substitute).
        let candidates: [Int]
        switch oldInterval {
        case 3, 4:
            // Third (minor/major) -> third in new chord, else sus4/sus2
            candidates = [3, 4, 5, 2]
        case 6, 7, 8:
            // Fifth (dim/perf/aug) -> fifth in new chord
            candidates = [7, 6, 8]
        case 10, 11:
            // Seventh (m7/maj7) -> seventh in new chord, else 6th/dim7
            candidates = [10, 11, 9]
        case 2, 13, 14, 15:
            // Second / Ninth (2, b9, 9, #9)
            candidates = [14, 2, 13, 15]
        case 5, 17, 18:
            // Fourth / Eleventh (4, 11, #11)
            candidates = [17, 5, 18]
        case 9, 20, 21:
            // Sixth / Thirteenth (6, b13, 13)
            candidates = [9, 21, 20]
        default:
            candidates = [oldInterval, mod]
        }

        // First try exact interval match, then mod-12 match within the functional group.
        for preferred in candidates {
            if newIntervals.contains(preferred) { return preferred }
        }
        for preferred in candidates {
            if let match = newIntervals.first(where: { $0 % 12 == preferred % 12 }) {
                return match
            }
        }

        // Fallback: closest interval by semitone distance in the new chord.
        return newIntervals.min { a, b in
            let da = abs((a % 12) - mod)
            let db = abs((b % 12) - mod)
            return da == db ? a < b : da < db
        } ?? 0
    }
}
