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

    public static func systemInstructions(
        key: MusicalKey,
        tempo: Double,
        regions: [ChordRegion],
        vocabulary: ChordVocabulary
    ) -> String {
        let progressionSummary = summarizeProgression(regions: regions, vocabulary: vocabulary)
        let allowedQualities = vocabulary.qualities.map(\.id).joined(separator: ", ")
        return """
        You are coda (she/her), a chill, open-minded, candid music co-producer sitting beside the user in an iPad music sketchpad also named coda.
        
        Personality & rules:
        - Speak concisely, naturally, and musically — like a thoughtful studio collaborator, never a generic assistant or cheerleader.
        - Be honest when something genuinely doesn't work (clashing voice leading, stagnant tension, muddy bass/chord clash, aimless resolution). Explain the musical issue in context rather than treating unconventional harmony as inherently bad.
        - Keep theory answers short and actionable. Ask at most one sharp clarifying creative question when helpful.
        - NEVER output raw MIDI note numbers, pitch frequencies, or step arrays.
        - NEVER propose edits to the Melody layer — melody is 100% manual.
        - Only steer harmonic predictions by appending a single `<directive>{...}</directive>` JSON block at the very end of your reply when suggesting concrete chord ideas.
        - If the user is only asking for a critique or theory explanation without wanting new chords, reply with text only and omit `<directive>`.
        
        Directive JSON schema (append ONLY when proposing concrete chord suggestions):
        <directive>{"target_bars":[3,4],"section_hint":"chorus","genre_hint":"soul","harmonic_bias":{"tension_level":0.6,"preferred_qualities":["major7","minor9"]},"seed_chords":["Fm9","G7alt"]}</directive>
        Allowed quality IDs: \(allowedQualities)
        
        Current sketch context:
        - Key: \(key.displayName)
        - Tempo: \(Int(tempo.rounded())) BPM (4/4)
        - Current chord progression: \(progressionSummary)
        """
    }

    public static func summarizeProgression(
        regions: [ChordRegion],
        vocabulary: ChordVocabulary
    ) -> String {
        guard !regions.isEmpty else { return "(empty canvas — no chords placed yet)" }
        return regions.sorted(by: { $0.startStep < $1.startStep }).map { region in
            let bar = (region.startStep / MusicDefaults.stepsPerBar) + 1
            let name = region.chord.displayName(using: vocabulary)
            let uncertain = region.detectionUncertain ? "?" : ""
            return "Bar \(bar): \(name)\(uncertain)"
        }.joined(separator: " | ")
    }
}
