import XCTest
@testable import CodaMusic

final class VoiceLeadingSolverTests: MusicTestCase {
    func testCloseDropTwoAndOpenCandidatesAreDistinctAndStable() throws {
        let v = try vocabulary()
        let solver = VoiceLeadingSolver()
        let c = try chord(0, "major7")
        let candidates = try solver.candidates(for: c, vocabulary: v)
        XCTAssertTrue(candidates.contains([48, 52, 55, 59]))
        XCTAssertTrue(candidates.contains([43, 48, 52, 59]))
        XCTAssertTrue(candidates.contains([48, 55, 64, 71]))
        XCTAssertEqual(candidates, candidates.sorted { $0.lexicographicallyPrecedes($1) })
        XCTAssertEqual(Set(candidates).count, candidates.count)
        XCTAssertEqual(candidates, try solver.candidates(for: c, vocabulary: v))
    }

    func testAllSlashPitchClassesStayLowestAndRespectRegister() throws {
        let v = try vocabulary()
        let solver = VoiceLeadingSolver()
        for slash in 0..<12 {
            let c = try chord(0, "major9", slash: slash)
            let candidates = try solver.candidates(for: c, vocabulary: v)
            for notes in candidates {
                XCTAssertEqual(notes[0] % 12, slash)
                XCTAssertGreaterThanOrEqual(notes[0], 36)
                XCTAssertLessThanOrEqual(notes.last!, 84)
                XCTAssertLessThanOrEqual(notes.last! - notes[0], 36)
                XCTAssertEqual(notes, notes.sorted())
                XCTAssertNoThrow(try Progression(regions: [region(chord: c, pitches: notes)], vocabulary: v))
            }
        }
    }

    func testInvalidAndImpossibleRegistersAndPrecedingInputThrow() throws {
        let v = try vocabulary()
        let c = try chord()
        var invalid = VoicingConfiguration()
        invalid.lowerMIDI = -1
        XCTAssertThrowsError(try VoiceLeadingSolver(configuration: invalid).solve([c], vocabulary: v))
        var narrow = VoicingConfiguration()
        narrow.lowerMIDI = 60
        narrow.upperMIDI = 61
        XCTAssertThrowsError(try VoiceLeadingSolver(configuration: narrow).solve([c], vocabulary: v))
        for notes in [[], [128], [64, 60], [60, 60]] {
            XCTAssertThrowsError(try VoiceLeadingSolver().solve([c], vocabulary: v, preceding: notes))
        }
        XCTAssertEqual(try VoiceLeadingSolver().solve([], vocabulary: v), [])
    }

    private func cost(_ path: [[Int]], solver: VoiceLeadingSolver, preceding: [Int]? = nil) -> Int {
        var result = path.reduce(0) { $0 + solver.registerCost($1) }
        if let preceding, let first = path.first { result += solver.transitionCost(from: preceding, to: first) }
        for i in path.indices.dropFirst() { result += solver.transitionCost(from: path[i - 1], to: path[i]) }
        return result
    }

    func testViterbiMatchesExhaustiveOptimumAndBeatsGreedyOnGeneratedInputs() throws {
        let v = try vocabulary()
        var config = VoicingConfiguration()
        config.lowerMIDI = 48
        config.upperMIDI = 67
        config.maximumSpan = 19
        let solver = VoiceLeadingSolver(configuration: config)
        let first = try chord(0, "major")
        let firstCandidates = try solver.candidates(for: first, vocabulary: v)
        var foundGreedyCounterexample = false
        // Search a small generated family, not a single canned progression. Every
        // compared optimum is enumerated independently of the solver recurrence.
        for middleRoot in 0..<12 {
            for lastRoot in 0..<12 {
                let chords = try [first, chord(middleRoot, "minor"), chord(lastRoot, "major")]
                let middle = try solver.candidates(for: chords[1], vocabulary: v)
                let last = try solver.candidates(for: chords[2], vocabulary: v)
                var optimum = Int.max
                for a in firstCandidates {
                    for b in middle {
                        for c in last { optimum = min(optimum, cost([a, b, c], solver: solver)) }
                    }
                }
                let solved = try solver.solve(chords, vocabulary: v)
                XCTAssertEqual(cost(solved, solver: solver), optimum)
                XCTAssertEqual(solved, try solver.solve(chords, vocabulary: v))
                var greedy: [[Int]] = []
                for layer in [firstCandidates, middle, last] {
                    let best = layer.min { a, b in
                        let ca = solver.registerCost(a) + (greedy.last.map { solver.transitionCost(from: $0, to: a) } ?? 0)
                        let cb = solver.registerCost(b) + (greedy.last.map { solver.transitionCost(from: $0, to: b) } ?? 0)
                        return ca == cb ? a.lexicographicallyPrecedes(b) : ca < cb
                    }!
                    greedy.append(best)
                }
                if cost(greedy, solver: solver) > optimum { foundGreedyCounterexample = true }
            }
        }
        XCTAssertTrue(foundGreedyCounterexample, "Must exercise a real look-ahead benefit")
    }

    func testPrecedingVoicingChangesInitialCostAndZeroCostTiesAreStable() throws {
        let v = try vocabulary()
        var config = VoicingConfiguration()
        config.registerWeight = 0
        let solver = VoiceLeadingSolver(configuration: config)
        let c = try chord(0, "major7")
        let previous = [60, 64, 67, 71]
        XCTAssertEqual(try solver.solve([c], vocabulary: v, preceding: previous), [previous])
        config.movementWeight = 0
        config.voiceCountPenalty = 0
        let tied = VoiceLeadingSolver(configuration: config)
        let first = try tied.candidates(for: c, vocabulary: v)[0]
        XCTAssertEqual(try tied.solve([c, c, c], vocabulary: v), [first, first, first])
    }
}
