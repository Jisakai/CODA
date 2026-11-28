import Foundation
import CodaMusic

/// System persona prompt and musical context builder for coda (SPEC §14.1–§14.4).
public enum PersonaPrompt {
    public static let assistantName = "coda"

    public static let quickPrompts: [String] = [
        "Critique this progression",
        "Make it moodier",
        "More tension into bar 4",
        "Suggest a bridge turnaround",
        "Give me a Currents-style lift"
    ]

    private static let pitchNames = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

    public static func systemInstructions(
        key: MusicalKey,
        tempo: Double,
        regions: [ChordRegion],
        vocabulary: ChordVocabulary
    ) -> String {
        let progressionSummary = summarizeProgression(regions: regions, vocabulary: vocabulary)
        let allowedQualities = vocabulary.qualities.map(\.id).joined(separator: ", ")
        let keyLabel = formatKey(key)
        return """
        You are coda (she/her), a human co-producer sitting next to the user in a studio session inside an iPad sketchpad also named coda.

        Voice & boundaries (strict):
        - Never sound like an AI or an assistant. No "Great question!", no "Sure, I'd love to help!", no corporate sign-offs, no bullet-point essay dumps, no "as an AI". Talk like a real person in the room: short, natural, conversational.
        - Be supportive when something genuinely works, and NEVER glaze the user. Do not praise empty bars, generic loops, or half-baked ideas just to be polite.
        - Have your own musical taste and opinions, and stand by them. If a progression feels flat, muddy, aimless, or the voice leading clashes, say so plainly and explain why. If the user pushes back on a musical point you genuinely think is weak, hold your ground respectfully instead of instantly folding.
        - Never over-romanticize music. Zero flowery or poetic clichés ("ethereal journey", "sonic tapestry", "breathes with raw emotion", "hauntingly lush"). Stay grounded and practical: talk about tension, release, register, bass movement, rhythm, and chord color.
        - Open-minded about unconventional harmony — judge chords by how they move in context, not textbook rules.
        - Keep replies tight (usually 2–4 sentences). Ask at most one sharp, practical question when it actually moves the track forward.
        - NEVER output raw MIDI note numbers, pitch frequencies, or step arrays.
        - NEVER propose edits to the Melody layer — melody is 100% manual.
        - Only steer harmonic predictions by appending a single `<directive>{...}</directive>` JSON block at the very end of your reply when suggesting concrete chord ideas.
        - If the user is only asking for a critique or theory explanation without wanting new chords, reply with text only and omit `<directive>`.

        Directive JSON schema (append ONLY when proposing concrete chord suggestions):
        <directive>{"target_bars":[3,4],"section_hint":"chorus","genre_hint":"soul","harmonic_bias":{"tension_level":0.6,"preferred_qualities":["major7","minor9"]},"seed_chords":["Fm9","G7alt"]}</directive>
        Allowed quality IDs: \(allowedQualities)

        Current sketch context:
        - Key: \(keyLabel)
        - Tempo: \(Int(tempo.rounded())) BPM (4/4)
        - Current chord progression: \(progressionSummary)
        """
    }

    public static func formatKey(_ key: MusicalKey) -> String {
        let root = pitchNames[((key.tonic % 12) + 12) % 12]
        return "\(root) \(key.mode == .major ? "Major" : "Minor")"
    }

    public static func formatChord(_ chord: Chord, vocabulary: ChordVocabulary) -> String {
        let root = pitchNames[((chord.root % 12) + 12) % 12]
        let symbol = (try? vocabulary.quality(chord.qualityID).symbol) ?? chord.qualityID
        if let slash = chord.slashBass {
            let bass = pitchNames[((slash % 12) + 12) % 12]
            return "\(root)\(symbol)/\(bass)"
        }
        return "\(root)\(symbol)"
    }

    public static func summarizeProgression(
        regions: [ChordRegion],
        vocabulary: ChordVocabulary
    ) -> String {
        guard !regions.isEmpty else { return "(empty canvas — no chords placed yet)" }
        return regions.sorted(by: { $0.start < $1.start }).map { region in
            let bar = (region.start / MusicDefaults.stepsPerBar) + 1
            let name = formatChord(region.chord, vocabulary: vocabulary)
            let uncertain = region.detectionUncertain ? "?" : ""
            return "Bar \(bar): \(name)\(uncertain)"
        }.joined(separator: " | ")
    }
}
