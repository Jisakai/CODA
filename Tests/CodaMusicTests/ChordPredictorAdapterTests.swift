import Foundation
import XCTest
@testable import CodaMusic

final class ChordPredictorAdapterTests: MusicTestCase {
    func testFallbackReportsIsModelLoadedFalseHonestly() throws {
        let v = try vocabulary()
        let predictor = CoreMLChordPredictor(vocabulary: v, key: MusicDefaults.key, bundle: nil)
        XCTAssertFalse(predictor.isModelLoaded)
    }

    func testConformsToChordSuggestionProviderForExistingAndNextSlots() throws {
        let v = try vocabulary()
        let predictor: any SteerableChordSuggestionProvider = CoreMLChordPredictor(vocabulary: v, key: MusicDefaults.key)

        let existing = try chord(0, "minor7", slash: 7)
        let extOptions = try predictor.suggestions(existing: existing, previous: nil, key: MusicDefaults.key, vocabulary: v)
        XCTAssertEqual(extOptions.count, 3)
        for option in extOptions {
            XCTAssertEqual(option.chord.root, 0)
            XCTAssertEqual(option.chord.slashBass, 7)
            XCTAssertNotEqual(option.chord, existing)
            XCTAssertGreaterThan(option.score, 0)
            XCTAssertLessThanOrEqual(option.score, 1.0)
        }
        // Ranked descending by score
        XCTAssertGreaterThanOrEqual(extOptions[0].score, extOptions[1].score)
        XCTAssertGreaterThanOrEqual(extOptions[1].score, extOptions[2].score)

        let nextOptions = try predictor.suggestions(existing: nil, previous: chord(7, "dominant7"), key: MusicDefaults.key, vocabulary: v)
        XCTAssertEqual(nextOptions.count, 3)
        XCTAssertGreaterThan(nextOptions[0].score, 0)
    }

    func testSteeredSuggestionsRespectPreferredQualitiesAndTensionLevel() throws {
        let v = try vocabulary()
        let p = try Progression(
            totalSteps: 32,
            regions: [region("r1", start: 0, length: 16, chord: chord(0, "minor7"))],
            vocabulary: v
        )
        let predictor = CoreMLChordPredictor(vocabulary: v, key: MusicDefaults.key)

        // Preferred quality steering on existing chord
        let preferredBias = HarmonicSteeringBias(
            tensionLevel: 0.9,
            preferredQualities: ["minor11"],
            sectionHint: "bridge",
            genreHint: "jazz"
        )
        let steered = try predictor.steeredSuggestions(in: p, at: 0, bias: preferredBias, limit: 3)
        XCTAssertEqual(steered.count, 3)
        XCTAssertEqual(steered[0].chord.qualityID, "minor11")
        XCTAssertEqual(steered[0].chord.root, 0)

        // Low tension vs high tension on empty slot (step 16)
        let simpleBias = HarmonicSteeringBias(tensionLevel: 0.0, genreHint: "pop")
        let tenseBias = HarmonicSteeringBias(tensionLevel: 1.0, genreHint: "jazz")

        let simpleNext = try predictor.steeredSuggestions(in: p, at: 16, bias: simpleBias, limit: 5)
        let tenseNext = try predictor.steeredSuggestions(in: p, at: 16, bias: tenseBias, limit: 5)
        XCTAssertEqual(simpleNext.count, 5)
        XCTAssertEqual(tenseNext.count, 5)

        let avgSimpleIntervals = Double(try simpleNext.map { try v.quality($0.chord.qualityID).intervals.count }.reduce(0, +)) / 5.0
        let avgTenseIntervals = Double(try tenseNext.map { try v.quality($0.chord.qualityID).intervals.count }.reduce(0, +)) / 5.0
        XCTAssertGreaterThan(avgTenseIntervals, avgSimpleIntervals)
    }

    func testSteeredSuggestionsSeedChordsBoostMatchingChord() throws {
        let v = try vocabulary()
        let p = try Progression(totalSteps: 32, regions: [], vocabulary: v)
        let predictor = CoreMLChordPredictor(vocabulary: v, key: MusicalKey(tonic: 0, mode: .major))

        let bias = HarmonicSteeringBias(tensionLevel: 0.5, preferredQualities: ["major7"], seedChords: ["Fmaj7"])
        let results = try predictor.steeredSuggestions(in: p, at: 0, bias: bias, limit: 5)
        XCTAssertTrue(results.contains { $0.chord.root == 5 && $0.chord.qualityID == "major7" })
    }

    func testSoftmaxNumericalStabilityAndNormalization() {
        let probs = CoreMLChordPredictor.softmax([1000.0, 1001.0, 999.0])
        XCTAssertEqual(probs.count, 3)
        XCTAssertEqual(probs.reduce(0, +), 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(probs[1], probs[0])
        XCTAssertGreaterThan(probs[0], probs[2])
    }
}
