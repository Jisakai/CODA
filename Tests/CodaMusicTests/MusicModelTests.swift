import Foundation
import XCTest
@testable import CodaMusic

class MusicTestCase: XCTestCase {
    func vocabulary() throws -> ChordVocabulary {
        try ChordVocabulary.load(in: Bundle(for: MusicTestCase.self))
    }

    func chord(_ root: Int = 0, _ quality: String = "minor7", slash: Int? = nil) throws -> Chord {
        try Chord(root: root, qualityID: quality, slashBass: slash)
    }

    func region(_ id: String = "a", start: Int = 0, length: Int = 16,
                chord: Chord? = nil, pitches: [Int]? = nil) throws -> ChordRegion {
        let identity = try chord ?? self.chord()
        let notes = try pitches ?? VoiceLeadingSolver().solve([identity], vocabulary: vocabulary())[0]
        return try ChordRegion(id: id, chord: identity, start: start, length: length, pitches: notes)
    }
}

final class MusicModelTests: MusicTestCase {
    func testBundledVocabularyExamplesFamiliesAndStableIDs() throws {
        let v = try vocabulary()
        for (id, intervals) in [("minor7", [0, 3, 7, 10]), ("major7", [0, 4, 7, 11]),
                                ("minor9", [0, 3, 7, 10, 14]), ("dominant7alt", [0, 4, 10, 13, 15, 20])] {
            XCTAssertEqual(try v.quality(id).intervals, intervals)
        }
        XCTAssertEqual(Set(v.qualities.map(\.id)).count, v.qualities.count)
        for family in ChordFamily.allCases { XCTAssertFalse(v.ring(family).isEmpty) }
        XCTAssertTrue(v.ring(.odd).contains { $0.id == "power" })
        for quality in v.qualities {
            XCTAssertEqual(quality.suggestions.count, 3)
            for id in quality.suggestions { XCTAssertNoThrow(try v.quality(id)) }
        }
    }

    func testRejectsMalformedVocabularyAndInvalidMetadata() throws {
        XCTAssertThrowsError(try ChordVocabulary(data: Data("{}".utf8)))
        let qualities = try vocabulary().qualities
        let encoded = try JSONEncoder().encode(qualities)
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        for field in ["id", "family", "intervals", "suggestions"] {
            var changed = objects
            switch field {
            case "id": changed[0][field] = objects[1][field]
            case "family": changed[0][field] = "invalid"
            case "intervals": changed[0][field] = [0, 4, 12]
            default: changed[0][field] = ["missing", "minor7", "major7"]
            }
            let bad = try JSONSerialization.data(withJSONObject: changed)
            XCTAssertThrowsError(try ChordVocabulary(data: bad), field)
        }
        XCTAssertThrowsError(try vocabulary().quality("missing"))
    }

    func testRejectsInvalidChordPitchesAndSpansWithoutIntegerOverflow() throws {
        XCTAssertThrowsError(try chord(-1))
        XCTAssertThrowsError(try chord(12))
        XCTAssertThrowsError(try chord(slash: 12))
        for notes in [[], [-1, 60], [60, 128], [60, 60]] {
            XCTAssertThrowsError(try region(pitches: notes))
        }
        XCTAssertThrowsError(try region(start: -1))
        XCTAssertThrowsError(try region(length: 0))
        XCTAssertThrowsError(try region(start: Int.max, length: 1))
        XCTAssertThrowsError(try LoopSpan(start: Int.max, bars: 1))
        XCTAssertThrowsError(try LoopSpan(bars: 0))
        XCTAssertThrowsError(try LoopSpan(bars: Int.max))
    }

    func testProgressionValidatesBoundsOverlapIDsAndIdentity() throws {
        let v = try vocabulary()
        let a = try region()
        XCTAssertThrowsError(try Progression(totalSteps: 0, vocabulary: v))
        XCTAssertThrowsError(try Progression(totalSteps: 17, vocabulary: v))
        XCTAssertThrowsError(try Progression(regions: [a, a], vocabulary: v))
        XCTAssertThrowsError(try Progression(regions: [a, region("b", start: 15)], vocabulary: v))
        XCTAssertThrowsError(try Progression(regions: [region(start: 120)], vocabulary: v))
        // Manual note voicings are permitted as retained chord labels; unknown quality IDs still fail.
        XCTAssertNoThrow(try Progression(regions: [region(pitches: [60, 64, 67])], vocabulary: v))
        XCTAssertNoThrow(try Progression(regions: [region(chord: chord(0, "major", slash: 4), pitches: [60, 64, 67])], vocabulary: v))
        XCTAssertThrowsError(try Progression(regions: [region(chord: chord(0, "missing"), pitches: [60])], vocabulary: v))
        let p = try Progression(regions: [region("b", start: 16), a], vocabulary: v)
        XCTAssertEqual(p.regions.map(\.id), ["a", "b"])
        XCTAssertEqual(try Progression(vocabulary: v).regions, [])
    }

    func testEveryVocabularyQualityCanBeVoicedAndValidatedAtEveryRoot() throws {
        let v = try vocabulary()
        for quality in v.qualities {
            for root in 0..<12 {
                let r = try region(chord: chord(root, quality.id))
                XCTAssertNoThrow(try Progression(regions: [r], vocabulary: v))
            }
        }
    }
}
