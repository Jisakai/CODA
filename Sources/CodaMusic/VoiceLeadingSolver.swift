import Foundation

/// All feel/cost choices are centralized here; see docs/M1-phase1.md.
public struct VoicingConfiguration: Equatable, Sendable {
    public var lowerMIDI = 36
    public var upperMIDI = 84
    public var centerMIDI = 60
    public var maximumSpan = 36
    public var movementWeight = 10
    public var registerWeight = 1
    public var voiceCountPenalty = 6
    public init() {}

    fileprivate func validate() throws {
        guard (0...127).contains(lowerMIDI), (lowerMIDI...127).contains(upperMIDI),
              (lowerMIDI...upperMIDI).contains(centerMIDI), (1...127).contains(maximumSpan),
              (0...100).contains(movementWeight), (0...100).contains(registerWeight),
              (0...100).contains(voiceCountPenalty) else { throw MusicError.invalidRegister }
    }
}

public struct VoiceLeadingSolver: Sendable {
    public let configuration: VoicingConfiguration
    public init(configuration: VoicingConfiguration = VoicingConfiguration()) {
        self.configuration = configuration
    }

    public func candidates(for chord: Chord, vocabulary: ChordVocabulary) throws -> [[Int]] {
        try configuration.validate()
        let pcs = try vocabulary.quality(chord.qualityID).intervals.map { ($0 + chord.root) % 12 }.sorted()
        var found = Set<[Int]>()
        for inversion in pcs.indices {
            let rotated = Array(pcs[inversion...]) + Array(pcs[..<inversion])
            for bass in configuration.lowerMIDI...configuration.upperMIDI where bass % 12 == rotated[0] {
                var close = [bass]
                for pc in rotated.dropFirst() {
                    let last = close[close.count - 1]
                    close.append(last + (pc - last % 12 + 11) % 12 + 1)
                }
                var shapes = [close]
                if close.count >= 4 {
                    var drop2 = close
                    drop2[drop2.count - 2] -= 12
                    shapes.append(drop2.sorted())
                }
                shapes.append(close.enumerated().map { $0.element + ($0.offset.isMultiple(of: 2) ? 0 : 12) }.sorted())
                for var notes in shapes {
                    if let slash = chord.slashBass, notes[0] % 12 != slash {
                        let below = notes[0] - 1
                        let pitch = below - (below % 12 - slash + 12) % 12
                        notes.insert(pitch, at: 0)
                    }
                    guard let low = notes.first, let high = notes.last,
                          low >= configuration.lowerMIDI, high <= configuration.upperMIDI,
                          high - low <= configuration.maximumSpan,
                          Set(notes).count == notes.count else { continue }
                    found.insert(notes)
                }
            }
        }
        let result = found.sorted { $0.lexicographicallyPrecedes($1) }
        guard !result.isEmpty else { throw MusicError.noVoicing }
        return result
    }

    func registerCost(_ pitches: [Int]) -> Int {
        pitches.reduce(0) { $0 + abs($1 - configuration.centerMIDI) * configuration.registerWeight }
    }

    /// Sorted rank matching, holding the last rank when cardinalities differ.
    func transitionCost(from: [Int], to: [Int]) -> Int {
        guard !from.isEmpty, !to.isEmpty else { return 0 }
        let motion = (0..<max(from.count, to.count)).reduce(0) {
            $0 + abs(from[min($1, from.count - 1)] - to[min($1, to.count - 1)])
        }
        return motion * configuration.movementWeight
            + abs(from.count - to.count) * configuration.voiceCountPenalty
    }

    /// Global linear-path Viterbi, not a greedy previous-chord lookup. Equal costs keep
    /// the first lexicographically ordered candidate/predecessor. No randomized ties.
    public func solve(_ chords: [Chord], vocabulary: ChordVocabulary,
                      preceding: [Int]? = nil) throws -> [[Int]] {
        try configuration.validate()
        if let preceding {
            guard !preceding.isEmpty, preceding == preceding.sorted(),
                  preceding.allSatisfy({ (0...127).contains($0) }), Set(preceding).count == preceding.count
            else { throw MusicError.invalidPitches }
        }
        guard !chords.isEmpty else { return [] }
        let layers = try chords.map { try candidates(for: $0, vocabulary: vocabulary) }
        var costs = layers[0].map { notes in
            registerCost(notes) + (preceding.map { transitionCost(from: $0, to: notes) } ?? 0)
        }
        var back: [[Int]] = [Array(repeating: -1, count: layers[0].count)]
        for layer in layers.indices.dropFirst() {
            var next = Array(repeating: Int.max, count: layers[layer].count)
            var parents = Array(repeating: 0, count: next.count)
            for j in layers[layer].indices {
                for i in layers[layer - 1].indices {
                    let cost = costs[i] + transitionCost(from: layers[layer - 1][i], to: layers[layer][j])
                        + registerCost(layers[layer][j])
                    if cost < next[j] { next[j] = cost; parents[j] = i }
                }
            }
            back.append(parents)
            costs = next
        }
        var index = costs.indices.min { costs[$0] == costs[$1] ? $0 < $1 : costs[$0] < costs[$1] }!
        var path = [[Int]]()
        for layer in layers.indices.reversed() {
            path.append(layers[layer][index])
            index = back[layer][index]
        }
        return Array(path.reversed())
    }
}
