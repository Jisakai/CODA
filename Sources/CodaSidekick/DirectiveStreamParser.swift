import Foundation
import CodaMusic

/// Validated `<directive>` payload parsed from the coda sidekick stream (SPEC §14.4).
public struct SidekickDirective: Codable, Hashable, Sendable {
    public struct HarmonicBias: Codable, Hashable, Sendable {
        public let tensionLevel: Double
        public let preferredQualities: [String]

        enum CodingKeys: String, CodingKey {
            case tensionLevel = "tension_level"
            case preferredQualities = "preferred_qualities"
        }

        public init(tensionLevel: Double = 0.5, preferredQualities: [String] = []) {
            self.tensionLevel = min(max(tensionLevel, 0.0), 1.0)
            self.preferredQualities = preferredQualities
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rawTension = try container.decodeIfPresent(Double.self, forKey: .tensionLevel) ?? 0.5
            self.tensionLevel = min(max(rawTension, 0.0), 1.0)
            self.preferredQualities = try container.decodeIfPresent([String].self, forKey: .preferredQualities) ?? []
        }
    }

    public let targetBars: [Int]
    public let sectionHint: String?
    public let genreHint: String?
    public let harmonicBias: HarmonicBias
    public let seedChords: [String]

    enum CodingKeys: String, CodingKey {
        case targetBars = "target_bars"
        case sectionHint = "section_hint"
        case genreHint = "genre_hint"
        case harmonicBias = "harmonic_bias"
        case seedChords = "seed_chords"
    }

    public init(
        targetBars: [Int],
        sectionHint: String? = nil,
        genreHint: String? = nil,
        harmonicBias: HarmonicBias = HarmonicBias(),
        seedChords: [String] = []
    ) {
        self.targetBars = targetBars
        self.sectionHint = sectionHint
        self.genreHint = genreHint
        self.harmonicBias = harmonicBias
        self.seedChords = seedChords
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bars = try container.decodeIfPresent([Int].self, forKey: .targetBars) ?? []
        self.targetBars = bars.filter { $0 >= 1 && $0 <= 1024 }
        self.sectionHint = try container.decodeIfPresent(String.self, forKey: .sectionHint)
        self.genreHint = try container.decodeIfPresent(String.self, forKey: .genreHint)
        self.harmonicBias = try container.decodeIfPresent(HarmonicBias.self, forKey: .harmonicBias) ?? HarmonicBias()
        self.seedChords = try container.decodeIfPresent([String].self, forKey: .seedChords) ?? []
    }

    public func toSteeringBias(validating vocabulary: ChordVocabulary) -> HarmonicSteeringBias {
        let validQualities = harmonicBias.preferredQualities.filter { vocabulary.quality($0) != nil }
        return HarmonicSteeringBias(
            tensionLevel: harmonicBias.tensionLevel,
            preferredQualities: validQualities,
            sectionHint: sectionHint,
            genreHint: genreHint,
            seedChords: seedChords
        )
    }
}

/// Real-time streaming parser that strips `<directive>...</directive>` across arbitrary token boundaries (SPEC §14.4).
public struct DirectiveStreamParser: Sendable {
    public static let openTag = "<directive>"
    public static let closeTag = "</directive>"
    public static let maxDirectiveBytes = 4096

    private enum State: Sendable {
        case visible
        case insideDirective
        case finishedDirective
    }

    private var state: State = .visible
    private var pendingBuffer: String = ""
    private var directiveBuffer: String = ""

    public private(set) var visibleText: String = ""
    public private(set) var parsedDirective: SidekickDirective?

    public init() {}

    /// Feed a newly streamed text chunk. Returns the incremental visible text delta safe to display.
    @discardableResult
    public mutating func append(_ chunk: String) -> String {
        guard !chunk.isEmpty else { return "" }
        var emitted = ""

        switch state {
        case .visible:
            pendingBuffer.append(chunk)
            if let openRange = pendingBuffer.range(of: Self.openTag) {
                let before = String(pendingBuffer[..<openRange.lowerBound])
                emitted.append(before)
                visibleText.append(before)
                let after = String(pendingBuffer[openRange.upperBound...])
                pendingBuffer = ""
                state = .insideDirective
                if !after.isEmpty {
                    emitted.append(append(after))
                }
            } else {
                let holdback = longestPartialPrefixSuffix(in: pendingBuffer, tag: Self.openTag)
                let emitCount = pendingBuffer.count - holdback
                if emitCount > 0 {
                    let splitIdx = pendingBuffer.index(pendingBuffer.startIndex, offsetBy: emitCount)
                    let safe = String(pendingBuffer[..<splitIdx])
                    emitted.append(safe)
                    visibleText.append(safe)
                    pendingBuffer = String(pendingBuffer[splitIdx...])
                }
            }

        case .insideDirective:
            directiveBuffer.append(chunk)
            if let closeRange = directiveBuffer.range(of: Self.closeTag) {
                let jsonPayload = String(directiveBuffer[..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let trailing = String(directiveBuffer[closeRange.upperBound...])
                directiveBuffer = ""
                state = .finishedDirective
                parseDirectivePayload(jsonPayload)
                if !trailing.isEmpty {
                    emitted.append(append(trailing))
                }
            } else if directiveBuffer.utf8.count > Self.maxDirectiveBytes {
                // Bounded payload protection: drop runaway malformed tag
                directiveBuffer = ""
                state = .finishedDirective
            }

        case .finishedDirective:
            // Any normal text after a closed directive is displayed directly
            emitted.append(chunk)
            visibleText.append(chunk)
        }

        return emitted
    }

    /// Flush any trailing buffered characters when the stream completes.
    @discardableResult
    public mutating func finish() -> String {
        var emitted = ""
        if state == .visible && !pendingBuffer.isEmpty {
            emitted = pendingBuffer
            visibleText.append(pendingBuffer)
            pendingBuffer = ""
        } else if state == .insideDirective {
            // Unclosed directive tag is malformed -> discard silently, never show raw tag or wrong ghosts
            directiveBuffer = ""
            parsedDirective = nil
        }
        visibleText = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        return emitted
    }

    private mutating func parseDirectivePayload(_ payload: String) {
        guard !payload.isEmpty,
              payload.utf8.count <= Self.maxDirectiveBytes,
              let data = payload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SidekickDirective.self, from: data),
              !decoded.targetBars.isEmpty || !decoded.seedChords.isEmpty || !decoded.harmonicBias.preferredQualities.isEmpty
        else {
            parsedDirective = nil
            return
        }
        parsedDirective = decoded
    }

    private func longestPartialPrefixSuffix(in text: String, tag: String) -> Int {
        let maxLen = min(text.count, tag.count - 1)
        guard maxLen > 0 else { return 0 }
        for len in stride(from: maxLen, through: 1, by: -1) {
            let suffix = text.suffix(len)
            let prefix = tag.prefix(len)
            if suffix == prefix {
                return len
            }
        }
        return 0
    }
}
