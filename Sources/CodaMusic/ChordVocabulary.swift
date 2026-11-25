import Foundation

public enum ChordFamily: String, Codable, CaseIterable, Sendable {
    case major, minor, odd
}

public struct ChordQuality: Codable, Equatable, Sendable {
    public let id: String
    public let symbol: String
    public let family: ChordFamily
    public let intervals: [Int]
    /// Stable ordered alternatives used by the rule provider, never a learned prediction.
    public let suggestions: [String]
}

public struct ChordVocabulary: Sendable {
    public let qualities: [ChordQuality]
    private let byID: [String: ChordQuality]

    public init(data: Data) throws {
        let decoded: [ChordQuality]
        do { decoded = try JSONDecoder().decode([ChordQuality].self, from: data) }
        catch { throw MusicError.invalidVocabulary }
        let ids = Set(decoded.map(\.id))
        guard decoded.count >= 3, ids.count == decoded.count else { throw MusicError.invalidVocabulary }
        for q in decoded {
            guard !q.id.isEmpty, q.intervals.first == 0, q.intervals.count >= 2,
                  q.intervals.count <= 8, q.intervals == q.intervals.sorted(),
                  q.intervals.allSatisfy({ (0...24).contains($0) }),
                  Set(q.intervals.map { $0 % 12 }).count == q.intervals.count,
                  q.suggestions.count >= 3, Set(q.suggestions).count == q.suggestions.count,
                  !q.suggestions.contains(q.id), q.suggestions.allSatisfy({ ids.contains($0) })
            else { throw MusicError.invalidVocabulary }
        }
        self.qualities = decoded
        self.byID = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    /// Explicit bundle keeps this Foundation module independent of an app or test host.
    public static func load(in bundle: Bundle) throws -> ChordVocabulary {
        guard let url = bundle.url(forResource: "vocab", withExtension: "json") else {
            throw MusicError.invalidVocabulary
        }
        return try ChordVocabulary(data: Data(contentsOf: url))
    }

    public func quality(_ id: String) throws -> ChordQuality {
        guard let quality = byID[id] else { throw MusicError.unknownQuality(id) }
        return quality
    }

    public func ring(_ family: ChordFamily) -> [ChordQuality] {
        qualities.filter { $0.family == family }
    }
}
