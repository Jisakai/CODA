import Foundation
#if canImport(CoreML)
import CoreML
#endif

/// External steering bias applied to chord predictor logits (SPEC §17).
public struct HarmonicSteeringBias: Codable, Hashable, Sendable {
    /// 0.0 = simple triads/diatonic, 0.5 = balanced 7ths, 1.0 = rich 9th/11th/13th/altered extensions.
    public var tensionLevel: Double
    /// Vocabulary quality IDs to boost (e.g. ["minor9", "major7sharp11"]).
    public var preferredQualities: [String]
    /// Section conditioning hint (e.g. "verse", "chorus", "bridge", "intro", "outro").
    public var sectionHint: String?
    /// Genre conditioning hint (e.g. "jazz", "soul", "pop", "electronic", "rock").
    public var genreHint: String?
    /// Optional chord name / quality hints (e.g. ["Cm7", "Fmaj7", "G7alt"]).
    public var seedChords: [String]

    public static let neutral = HarmonicSteeringBias()

    public init(
        tensionLevel: Double = 0.5,
        preferredQualities: [String] = [],
        sectionHint: String? = nil,
        genreHint: String? = nil,
        seedChords: [String] = []
    ) {
        self.tensionLevel = min(1.0, max(0.0, tensionLevel.isFinite ? tensionLevel : 0.5))
        self.preferredQualities = preferredQualities
        self.sectionHint = sectionHint
        self.genreHint = genreHint
        self.seedChords = seedChords
    }
}

/// Steerable chord suggestion interface (SPEC §7.5, §17).
public protocol SteerableChordSuggestionProvider: ChordSuggestionProvider, Sendable {
    func steeredSuggestions(
        in progression: Progression,
        at step: Int,
        bias: HarmonicSteeringBias,
        limit: Int
    ) throws -> [ChordSuggestion]
}

/// Off-thread Core ML chord predictor adapter with external logit steering and
/// honest rule-based fallback when `ChordPredictor.mlmodelc`/`.mlpackage` is not bundled.
public final class CoreMLChordPredictor: SteerableChordSuggestionProvider, @unchecked Sendable {
    public let vocabulary: ChordVocabulary
    private let ruleEngine = RuleBasedChordSuggestions()
    private let lock = NSLock()
    private var defaultKey: MusicalKey

    #if canImport(CoreML)
    private var model: MLModel?
    #endif

    /// Explicitly reports whether a real Core ML model is currently loaded.
    /// Never faked when falling back to rule-based scoring.
    public var isModelLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        #if canImport(CoreML)
        return model != nil
        #else
        return false
        #endif
    }

    public var key: MusicalKey {
        get {
            lock.lock()
            defer { lock.unlock() }
            return defaultKey
        }
        set {
            lock.lock()
            defaultKey = newValue
            lock.unlock()
        }
    }

    public init(
        vocabulary: ChordVocabulary,
        key: MusicalKey = MusicDefaults.key,
        bundle: Bundle? = nil,
        modelName: String = "ChordPredictor",
        loadSynchronously: Bool = false
    ) {
        self.vocabulary = vocabulary
        self.defaultKey = key

        if let bundle, let url = Self.locateModelURL(named: modelName, in: bundle) {
            if loadSynchronously {
                try? loadModel(from: url)
            } else {
                loadModelAsync(from: url)
            }
        }
    }

    public func loadModel(from url: URL) throws {
        #if canImport(CoreML)
        let compiledURL: URL
        if url.pathExtension == "mlpackage" || url.pathExtension == "mlmodel" {
            compiledURL = try MLModel.compileModel(at: url)
        } else {
            compiledURL = url
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let loaded = try MLModel(contentsOf: compiledURL, configuration: configuration)
        lock.lock()
        self.model = loaded
        lock.unlock()
        #endif
    }

    public func loadModelAsync(from url: URL) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            try? self?.loadModel(from: url)
        }
    }

    private static func locateModelURL(named name: String, in bundle: Bundle) -> URL? {
        if let compiled = bundle.url(forResource: name, withExtension: "mlmodelc") {
            return compiled
        }
        if let package = bundle.url(forResource: name, withExtension: "mlpackage") {
            return package
        }
        return nil
    }

    // MARK: - ChordSuggestionProvider

    public func suggestions(
        existing: Chord?,
        previous: Chord?,
        key: MusicalKey,
        vocabulary: ChordVocabulary
    ) throws -> [ChordSuggestion] {
        try rankCandidates(
            existing: existing,
            previous: previous,
            following: nil,
            contextChords: previous.map { [$0] } ?? [],
            key: key,
            vocabulary: vocabulary,
            bias: .neutral,
            limit: 3
        )
    }

    // MARK: - SteerableChordSuggestionProvider

    public func steeredSuggestions(
        in progression: Progression,
        at step: Int,
        bias: HarmonicSteeringBias,
        limit: Int
    ) throws -> [ChordSuggestion] {
        try steeredSuggestions(
            in: progression,
            at: step,
            key: self.key,
            vocabulary: self.vocabulary,
            bias: bias,
            limit: limit
        )
    }

    public func steeredSuggestions(
        in progression: Progression,
        at step: Int,
        key: MusicalKey,
        vocabulary: ChordVocabulary,
        bias: HarmonicSteeringBias,
        limit: Int
    ) throws -> [ChordSuggestion] {
        guard step >= 0, step < progression.totalSteps else { throw MusicError.invalidSpan }
        guard limit > 0 else { return [] }

        let existingRegion = progression.regions.first { step >= $0.start && step < $0.end }
        let previousRegion = progression.regions.filter { $0.end <= (existingRegion?.start ?? step) }.max { $0.end < $1.end }
        let followingRegion = progression.regions.filter { $0.start >= (existingRegion?.end ?? (step + 1)) }.min { $0.start < $1.start }

        return try rankCandidates(
            existing: existingRegion?.chord,
            previous: previousRegion?.chord,
            following: followingRegion?.chord,
            contextChords: progression.regions.map(\.chord),
            key: key,
            vocabulary: vocabulary,
            bias: bias,
            limit: limit
        )
    }

    // MARK: - Inference & Logit Steering

    private func rankCandidates(
        existing: Chord?,
        previous: Chord?,
        following: Chord?,
        contextChords: [Chord],
        key: MusicalKey,
        vocabulary: ChordVocabulary,
        bias: HarmonicSteeringBias,
        limit: Int
    ) throws -> [ChordSuggestion] {
        if let existing { _ = try vocabulary.quality(existing.qualityID) }
        if let previous { _ = try vocabulary.quality(previous.qualityID) }

        let qualities = vocabulary.qualities
        let classCount = 12 * qualities.count
        guard classCount > 0 else { return [] }

        // 1. Obtain raw logits from Core ML if loaded, else deterministic harmonic baseline.
        let baseLogits = predictCoreMLLogits(
            contextChords: contextChords,
            existing: existing,
            classCount: classCount,
            vocabulary: vocabulary
        ) ?? buildRuleBaselineLogits(
            existing: existing,
            previous: previous,
            following: following,
            key: key,
            vocabulary: vocabulary
        )

        // 2. Apply external steering logit bias vector (SPEC §17).
        let steeringBias = Self.buildLogitBiasVector(vocabulary: vocabulary, key: key, bias: bias)
        var combined = [Double](repeating: 0, count: classCount)
        for i in 0..<classCount {
            combined[i] = baseLogits[i] + steeringBias[i]
        }

        // 3. Build candidate pool:
        //    - Center-masked (existing != nil): preserve existing root & slashBass, exclude current chord.
        //    - End-masked (existing == nil): consider all (root, quality) pairs.
        struct ScoredCandidate {
            let chord: Chord
            let function: HarmonicFunction
            let logit: Double
            let rootOrder: Int
            let qualityOrder: Int
        }

        var pool: [ScoredCandidate] = []
        if let existing {
            for (qIndex, quality) in qualities.enumerated() where quality.id != existing.qualityID {
                let classIdx = existing.root * qualities.count + qIndex
                let chord = try Chord(root: existing.root, qualityID: quality.id, slashBass: existing.slashBass)
                pool.append(ScoredCandidate(
                    chord: chord,
                    function: ruleEngine.function(of: chord, in: key),
                    logit: combined[classIdx],
                    rootOrder: existing.root,
                    qualityOrder: qIndex
                ))
            }
        } else {
            for root in 0..<12 {
                for (qIndex, quality) in qualities.enumerated() {
                    let classIdx = root * qualities.count + qIndex
                    let chord = try Chord(root: root, qualityID: quality.id)
                    pool.append(ScoredCandidate(
                        chord: chord,
                        function: ruleEngine.function(of: chord, in: key),
                        logit: combined[classIdx],
                        rootOrder: root,
                        qualityOrder: qIndex
                    ))
                }
            }
        }

        guard !pool.isEmpty else { return [] }
        let probabilities = Self.softmax(pool.map(\.logit))

        let ranked = zip(pool, probabilities).sorted { lhs, rhs in
            if abs(lhs.1 - rhs.1) > 1e-12 { return lhs.1 > rhs.1 }
            if lhs.0.rootOrder != rhs.0.rootOrder { return lhs.0.rootOrder < rhs.0.rootOrder }
            return lhs.0.qualityOrder < rhs.0.qualityOrder
        }

        return ranked.prefix(limit).map { item in
            ChordSuggestion(chord: item.0.chord, function: item.0.function, score: item.1)
        }
    }

    private func predictCoreMLLogits(
        contextChords: [Chord],
        existing: Chord?,
        classCount: Int,
        vocabulary: ChordVocabulary
    ) -> [Double]? {
        #if canImport(CoreML)
        lock.lock()
        let activeModel = self.model
        lock.unlock()
        guard let activeModel else { return nil }

        let qualities = vocabulary.qualities
        let qualityIndex = Dictionary(uniqueKeysWithValues: qualities.enumerated().map { ($0.element.id, $0.offset) })
        let maskTokenID = Int32(classCount + 1)

        var tokenIDs: [Int32] = contextChords.compactMap { chord in
            guard let qIdx = qualityIndex[chord.qualityID] else { return nil }
            return Int32(chord.root * qualities.count + qIdx + 1)
        }
        if existing == nil {
            tokenIDs.append(maskTokenID)
        } else if tokenIDs.isEmpty {
            tokenIDs = [maskTokenID]
        }

        guard let inputArray = try? MLMultiArray(shape: [1, NSNumber(value: tokenIDs.count)], dataType: .int32) else {
            return nil
        }
        for (idx, token) in tokenIDs.enumerated() {
            inputArray[idx] = NSNumber(value: token)
        }

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["input_ids": MLFeatureValue(multiArray: inputArray)]),
              let output = try? activeModel.prediction(from: provider),
              let logitsArray = output.featureValue(for: "logits")?.multiArrayValue,
              logitsArray.count >= classCount else {
            return nil
        }

        var logits = [Double](repeating: 0, count: classCount)
        for i in 0..<classCount {
            logits[i] = logitsArray[i].doubleValue
        }
        return logits
        #else
        return nil
        #endif
    }

    private func buildRuleBaselineLogits(
        existing: Chord?,
        previous: Chord?,
        following: Chord?,
        key: MusicalKey,
        vocabulary: ChordVocabulary
    ) -> [Double] {
        let qualities = vocabulary.qualities
        let classCount = 12 * qualities.count
        var logits = [Double](repeating: 0.0, count: classCount)

        let scaleDegrees: Set<Int> = key.mode == .major
            ? [0, 2, 4, 5, 7, 9, 11]
            : [0, 2, 3, 5, 7, 8, 10]

        if let existing, let existingQuality = try? vocabulary.quality(existing.qualityID) {
            for (qIdx, quality) in qualities.enumerated() {
                let classIdx = existing.root * qualities.count + qIdx
                if let rank = existingQuality.suggestions.firstIndex(of: quality.id) {
                    logits[classIdx] += 3.0 - Double(rank) * 0.45
                }
                if quality.family == existingQuality.family {
                    logits[classIdx] += 0.8
                }
            }
            return logits
        }

        let ruleTop = (try? ruleEngine.suggestions(existing: nil, previous: previous, key: key, vocabulary: vocabulary)) ?? []
        let priorFunction = previous.map { ruleEngine.function(of: $0, in: key) }

        for root in 0..<12 {
            let degree = (root - key.tonic + 12) % 12
            let inScale = scaleDegrees.contains(degree)
            let rootFunc = (try? Chord(root: root, qualityID: qualities[0].id)).map { ruleEngine.function(of: $0, in: key) } ?? .borrowed

            for (qIdx, quality) in qualities.enumerated() {
                let classIdx = root * qualities.count + qIdx
                var score = inScale ? 0.9 : -0.4

                // Functional motion bonus
                switch (priorFunction, rootFunc) {
                case (.some(.dominant), .tonic): score += 1.6
                case (.some(.subdominant), .dominant): score += 1.6
                case (.some(.tonic), .subdominant): score += 1.4
                case (.none, .tonic): score += 1.2
                default: break
                }

                // Avoid repeating exact previous chord as top-1 next chord
                if let previous, previous.root == root && previous.qualityID == quality.id {
                    score -= 1.2
                }

                // Voice-leading proximity to following chord if center-filling
                if let following {
                    let dist = min((root - following.root + 12) % 12, (following.root - root + 12) % 12)
                    if dist == 5 || dist == 7 { score += 0.45 }
                }

                // Strong prior from RuleBasedChordSuggestions
                if let rank = ruleTop.firstIndex(where: { $0.chord.root == root && $0.chord.qualityID == quality.id }) {
                    score += 2.2 - Double(rank) * 0.35
                }

                logits[classIdx] = score
            }
        }
        return logits
    }

    static func buildLogitBiasVector(
        vocabulary: ChordVocabulary,
        key: MusicalKey,
        bias: HarmonicSteeringBias
    ) -> [Double] {
        let qualities = vocabulary.qualities
        let classCount = 12 * qualities.count
        var vector = [Double](repeating: 0.0, count: classCount)

        let preferredSet = Set(bias.preferredQualities)
        let genre = bias.genreHint?.lowercased()
        let section = bias.sectionHint?.lowercased()
        let seedParsed = parseSeedHints(bias.seedChords, vocabulary: vocabulary)
        let rule = RuleBasedChordSuggestions()

        for root in 0..<12 {
            let dummyFunc = (try? Chord(root: root, qualityID: qualities[0].id)).map { rule.function(of: $0, in: key) } ?? .borrowed
            for (qIdx, quality) in qualities.enumerated() {
                let classIdx = root * qualities.count + qIdx
                var delta = 0.0

                // 1. Tension steering: complexity score in [0, 1]
                let complexity = qualityComplexity(quality)
                let tensionMatch = 1.0 - abs(complexity - bias.tensionLevel)
                delta += (tensionMatch - 0.5) * 2.4

                // 2. Explicit quality boost
                if preferredSet.contains(quality.id) {
                    delta += 2.5
                }

                // 3. Genre conditioning
                if let genre {
                    delta += genreBias(genre: genre, quality: quality)
                }

                // 4. Section conditioning
                if let section {
                    delta += sectionBias(section: section, function: dummyFunc, quality: quality)
                }

                // 5. Seed chord hints
                for seed in seedParsed {
                    if seed.root == root && seed.qualityID == quality.id {
                        delta += 1.8
                    } else if seed.root == root {
                        delta += 0.5
                    } else if seed.qualityID == quality.id {
                        delta += 0.4
                    }
                }

                vector[classIdx] = delta
            }
        }
        return vector
    }

    static func softmax(_ logits: [Double]) -> [Double] {
        guard let maxVal = logits.max() else { return [] }
        let exps = logits.map { exp($0 - maxVal) }
        let sum = exps.reduce(0.0, +)
        guard sum > 0, sum.isFinite else {
            return Array(repeating: 1.0 / Double(logits.count), count: logits.count)
        }
        return exps.map { $0 / sum }
    }

    private static func qualityComplexity(_ quality: ChordQuality) -> Double {
        let count = quality.intervals.count
        let hasAltered = quality.id.contains("alt") || quality.id.contains("flat") || quality.id.contains("sharp")
        let hasUpperExt = quality.intervals.contains { $0 >= 14 }
        if hasAltered { return 1.0 }
        if hasUpperExt || count >= 5 { return 0.85 }
        if count == 4 { return 0.5 }
        return 0.15
    }

    private static func genreBias(genre: String, quality: ChordQuality) -> Double {
        if genre.contains("jazz") || genre.contains("soul") || genre.contains("rnb") {
            if quality.intervals.count >= 4 { return 0.8 }
            if quality.id.contains("9") || quality.id.contains("11") || quality.id.contains("13") { return 1.1 }
            return -0.3
        }
        if genre.contains("pop") || genre.contains("rock") {
            if ["major", "minor", "add9", "sus2", "sus4", "power"].contains(quality.id) { return 0.9 }
            if quality.id.contains("alt") || quality.id.contains("flat9") { return -0.6 }
            return 0.0
        }
        if genre.contains("electronic") || genre.contains("house") || genre.contains("lofi") {
            if ["minor7", "minor9", "major7", "major9", "sus2"].contains(quality.id) { return 0.9 }
            return 0.0
        }
        return 0.0
    }

    private static func sectionBias(section: String, function: HarmonicFunction, quality: ChordQuality) -> Double {
        switch section {
        case "chorus":
            return (function == .tonic || function == .subdominant ? 0.5 : 0.0) + (quality.family == .major ? 0.3 : 0.0)
        case "bridge":
            return (function == .borrowed || function == .dominant ? 0.7 : 0.0)
        case "outro":
            return function == .tonic ? 0.8 : -0.1
        case "verse", "intro":
            return function == .tonic || function == .subdominant ? 0.3 : 0.0
        default:
            return 0.0
        }
    }

    private static func parseSeedHints(_ seeds: [String], vocabulary: ChordVocabulary) -> [(root: Int?, qualityID: String?)] {
        let rootNames: [(String, Int)] = [
            ("C#", 1), ("Db", 1), ("D#", 3), ("Eb", 3), ("F#", 6), ("Gb", 6),
            ("G#", 8), ("Ab", 8), ("A#", 10), ("Bb", 10),
            ("C", 0), ("D", 2), ("E", 4), ("F", 5), ("G", 7), ("A", 9), ("B", 11)
        ]
        return seeds.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if (try? vocabulary.quality(trimmed)) != nil {
                return (nil, trimmed)
            }
            for (prefix, pc) in rootNames where trimmed.hasPrefix(prefix) {
                let suffix = String(trimmed.dropFirst(prefix.count))
                let matchedQuality = vocabulary.qualities.first { $0.symbol == suffix || $0.id == suffix }?.id
                return (pc, matchedQuality)
            }
            return nil
        }
    }
}
