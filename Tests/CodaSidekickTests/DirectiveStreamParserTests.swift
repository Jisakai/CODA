import XCTest
@testable import CodaSidekick
import CodaMusic

final class DirectiveStreamParserTests: XCTestCase {
    func testStripsDirectiveAcrossArbitraryTokenBoundaries() throws {
        var parser = DirectiveStreamParser()
        let chunks = [
            "Try a darker turnaround ",
            "into bar 4. <dir",
            "ect",
            "ive>{\"target_bars\":[3,4],",
            "\"section_hint\":\"chorus\",",
            "\"genre_hint\":\"soul\",",
            "\"harmonic_bias\":{\"tension_level\":0.75,\"preferred_qualities\":[\"minor9\",\"dominant7alt\"]},",
            "\"seed_chords\":[\"Fm9\",\"G7alt\"]}",
            "</direct",
            "ive>"
        ]
        var streamed = ""
        for chunk in chunks {
            streamed.append(parser.append(chunk))
        }
        streamed.append(parser.finish())

        XCTAssertEqual(parser.visibleText, "Try a darker turnaround into bar 4.")
        XCTAssertFalse(streamed.contains("<directive>"))
        XCTAssertFalse(streamed.contains("target_bars"))

        let directive = try XCTUnwrap(parser.parsedDirective)
        XCTAssertEqual(directive.targetBars, [3, 4])
        XCTAssertEqual(directive.sectionHint, "chorus")
        XCTAssertEqual(directive.genreHint, "soul")
        XCTAssertEqual(directive.harmonicBias.tensionLevel, 0.75, accuracy: 0.001)
        XCTAssertEqual(directive.harmonicBias.preferredQualities, ["minor9", "dominant7alt"])
        XCTAssertEqual(directive.seedChords, ["Fm9", "G7alt"])
    }

    func testMalformedDirectiveYieldsTextOnlyAndNoDirective() {
        var parser = DirectiveStreamParser()
        _ = parser.append("That Abmaj7 feels a bit static here. <directive>{not valid json</directive>")
        _ = parser.finish()

        XCTAssertEqual(parser.visibleText, "That Abmaj7 feels a bit static here.")
        XCTAssertNil(parser.parsedDirective)
    }

    func testUnclosedDirectiveIsDiscardedSafely() {
        var parser = DirectiveStreamParser()
        _ = parser.append("Keep the root movement steady.<directive>{\"target_bars\":[2]}")
        _ = parser.finish()

        XCTAssertEqual(parser.visibleText, "Keep the root movement steady.")
        XCTAssertNil(parser.parsedDirective)
    }

    func testPlainTextWithoutDirectivePassesThroughCleanly() {
        var parser = DirectiveStreamParser()
        _ = parser.append("The jump from Cm7 to F#dim clashes with the bass.")
        _ = parser.finish()

        XCTAssertEqual(parser.visibleText, "The jump from Cm7 to F#dim clashes with the bass.")
        XCTAssertNil(parser.parsedDirective)
    }

    func testPersonaPromptIncludesCritiqueAndManualMelodyConstraint() throws {
        let vocab = try ChordVocabulary.load(in: Bundle(for: Self.self))
        let prompt = PersonaPrompt.systemInstructions(
            key: MusicDefaults.key,
            tempo: 124,
            regions: [],
            vocabulary: vocab
        )
        XCTAssertTrue(prompt.contains("coda"))
        XCTAssertTrue(prompt.contains("100% manual"))
        XCTAssertTrue(prompt.contains("NEVER output raw MIDI"))
        XCTAssertTrue(prompt.contains("<directive>"))
    }
}
