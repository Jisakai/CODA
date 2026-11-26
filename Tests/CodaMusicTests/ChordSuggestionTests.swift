import XCTest
@testable import CodaMusic

final class ChordSuggestionTests: MusicTestCase {
    func testAdditiveSuggestionsExtendTheExistingTriadAndRemainAtomicEdits() throws {
        let v = try vocabulary()
        let provider = RuleBasedChordSuggestions()
        for (base, expected) in [("major", ["add9", "add11"]),
                                 ("minor", ["minorAdd9", "minorAdd11"])] {
            for root in 0..<12 {
                let original = try chord(root, base, slash: (root + 7) % 12)
                let initial = try Progression(regions: [region(chord: original)], vocabulary: v)
                let options = try provider.suggestions(existing: original, previous: nil, key: MusicDefaults.key, vocabulary: v)
                XCTAssertEqual(Array(options.prefix(2).map(\.chord.qualityID)), expected)
                for option in options.prefix(2) {
                    XCTAssertEqual(option.chord.root, original.root)
                    XCTAssertEqual(option.chord.slashBass, original.slashBass)
                    let baseTones = Set(try v.quality(base).intervals)
                    let addedTones = Set(try v.quality(option.chord.qualityID).intervals)
                    XCTAssertTrue(baseTones.isStrictSubset(of: addedTones))
                    XCTAssertEqual(addedTones.subtracting(baseTones).count, 1)
                    var editor = ProgressionEditor(initial)
                    try editor.apply([.swap(id: "a", chord: option.chord)], vocabulary: v)
                    XCTAssertEqual(editor.progression.regions[0].chord, option.chord)
                    XCTAssertEqual(editor.progression.regions[0].start, 0)
                    XCTAssertEqual(editor.progression.regions[0].length, 16)
                    XCTAssertTrue(editor.undo())
                    XCTAssertEqual(editor.progression, initial)
                    XCTAssertFalse(editor.undo())
                }
            }
        }
    }

    func testAdditiveSuggestionMetadataNeverRemovesAnExistingPitchClass() throws {
        let v = try vocabulary()
        for quality in v.qualities {
            for id in quality.suggestions where id.lowercased().contains("add") {
                let candidate = try v.quality(id)
                XCTAssertTrue(Set(quality.intervals.map { $0 % 12 }).isSubset(of:
                    Set(candidate.intervals.map { $0 % 12 })), "\(quality.id) -> \(id)")
            }
        }
    }

    func testExistingSuggestionsUseVocabularyPreserveRootAndSlashAndExcludeCurrent() throws {
        let v = try vocabulary()
        let provider: any ChordSuggestionProvider = RuleBasedChordSuggestions()
        for quality in v.qualities {
            let current = try chord(8, quality.id, slash: 3)
            let options = try provider.suggestions(existing: current, previous: nil, key: MusicDefaults.key, vocabulary: v)
            XCTAssertEqual(options.count, 3)
            XCTAssertEqual(options.map(\.chord.qualityID), Array(quality.suggestions.prefix(3)))
            XCTAssertEqual(Set(options.map(\.chord)).count, 3)
            for option in options {
                XCTAssertEqual(option.chord.root, 8)
                XCTAssertEqual(option.chord.slashBass, 3)
                XCTAssertNotEqual(option.chord, current)
            }
            XCTAssertEqual(options, try provider.suggestions(existing: current, previous: nil, key: MusicDefaults.key, vocabulary: v))
        }
    }

    func testNextChordsFollowKeyAndFunctionWithExtendedQualities() throws {
        let v = try vocabulary()
        let provider = RuleBasedChordSuggestions()
        let key = MusicDefaults.key
        let fromTonic = try provider.suggestions(existing: nil, previous: chord(), key: key, vocabulary: v)
        XCTAssertEqual(fromTonic.map(\.chord.root), [5, 7, 0])
        XCTAssertEqual(fromTonic.map(\.chord.qualityID), ["minor7", "dominant7", "minor7"])
        let fromDominant = try provider.suggestions(existing: nil, previous: chord(7, "dominant7"), key: key, vocabulary: v)
        XCTAssertEqual(fromDominant[0].chord, try chord())
        XCTAssertEqual(fromDominant[0].function, .tonic)
        let fromSub = try provider.suggestions(existing: nil, previous: chord(5), key: key, vocabulary: v)
        XCTAssertEqual(fromSub[0].chord, try chord(7, "dominant7"))
        let dMajor = MusicalKey(tonic: 2, mode: .major)
        let empty = try provider.suggestions(existing: nil, previous: nil, key: dMajor, vocabulary: v)
        XCTAssertEqual(empty.map(\.chord.root), [7, 9, 2])
        XCTAssertEqual(empty.map(\.chord.qualityID), ["major7", "dominant7", "major7"])
        XCTAssertEqual(empty, try provider.suggestions(existing: nil, previous: nil, key: dMajor, vocabulary: v))
        XCTAssertThrowsError(try provider.suggestions(existing: chord(0, "missing"), previous: nil, key: key, vocabulary: v))
        XCTAssertThrowsError(try provider.suggestions(existing: nil, previous: chord(0, "missing"), key: key, vocabulary: v))
    }
}
