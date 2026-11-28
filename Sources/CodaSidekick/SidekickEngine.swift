import Foundation
import Observation
import CodaMusic

public struct SidekickMessage: Identifiable, Hashable, Sendable {
    public enum Role: String, Sendable {
        case user
        case assistant
        case status
    }

    public let id: UUID
    public let role: Role
    public var text: String
    public let timestamp: Date
    public var hasDirectiveGhosts: Bool

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        timestamp: Date = Date(),
        hasDirectiveGhosts: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.hasDirectiveGhosts = hasDirectiveGhosts
    }
}

/// Non-destructive AI ghost chord proposal rendered in `#ddb7ff` on the chord strip & roll (SPEC §14.4).
public struct GhostChordProposal: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let startStep: Int
    public let lengthSteps: Int
    public let chord: Chord
    public let pitches: [Int]
    public let reason: String

    public init(
        id: UUID = UUID(),
        startStep: Int,
        lengthSteps: Int,
        chord: Chord,
        pitches: [Int],
        reason: String
    ) {
        self.id = id
        self.startStep = startStep
        self.lengthSteps = lengthSteps
        self.chord = chord
        self.pitches = pitches
        self.reason = reason
    }

    public var endStep: Int { startStep + lengthSteps }
}

/// Coordinates streaming conversation with coda, `<directive>` parsing, and steered ghost generation (SPEC §14).
@MainActor
@Observable
public final class SidekickEngine {
    public private(set) var messages: [SidekickMessage] = []
    public private(set) var isStreaming: Bool = false
    public private(set) var modelState: SidekickModelState = .notDownloaded
    public private(set) var activeGhosts: [GhostChordProposal] = []
    public private(set) var lastDirective: SidekickDirective?
    public var isTyping: Bool = false

    private let modelManager: SidekickModelManager
    private let predictor: (any SteerableChordSuggestionProvider)?
    private let solver: VoiceLeadingSolver
    private var activeStreamTask: Task<Void, Never>?

    public init(
        modelManager: SidekickModelManager = SidekickModelManager(),
        predictor: (any SteerableChordSuggestionProvider)? = nil,
        solver: VoiceLeadingSolver = VoiceLeadingSolver()
    ) {
        self.modelManager = modelManager
        self.predictor = predictor
        self.solver = solver
        Task { [weak self] in
            let initial = await modelManager.state
            await MainActor.run {
                self?.modelState = initial
            }
        }
    }

    public func startModelDownload() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.modelManager.ensureModelReady { progress in
                    Task { @MainActor [weak self] in
                        self?.modelState = .downloading(progress: progress)
                    }
                }
                self.modelState = await self.modelManager.state
            } catch {
                self.modelState = await self.modelManager.state
            }
        }
    }

    public func cancelModelDownload() {
        Task { [weak self] in
            guard let self else { return }
            await self.modelManager.cancelDownload()
            self.modelState = await self.modelManager.state
        }
    }

    public func cancelStreaming() {
        activeStreamTask?.cancel()
        activeStreamTask = nil
        isStreaming = false
    }

    public func send(
        prompt: String,
        key: MusicalKey,
        progression: Progression,
        tempo: Double,
        vocabulary: ChordVocabulary
    ) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cancelStreaming()

        messages.append(SidekickMessage(role: .user, text: trimmed))
        let assistantID = UUID()
        messages.append(SidekickMessage(id: assistantID, role: .assistant, text: ""))
        isStreaming = true

        let instructions = PersonaPrompt.systemInstructions(
            key: key,
            tempo: tempo,
            regions: progression.regions,
            vocabulary: vocabulary
        )

        activeStreamTask = Task { [weak self] in
            guard let self else { return }
            var parser = DirectiveStreamParser()
            do {
                let stream = await self.modelManager.streamCompletion(
                    systemInstructions: instructions,
                    userMessage: trimmed
                )
                for try await chunk in stream {
                    if Task.isCancelled { break }
                    let delta = parser.append(chunk)
                    if !delta.isEmpty {
                        self.appendVisibleText(delta, to: assistantID)
                    }
                }
                let tail = parser.finish()
                if !tail.isEmpty {
                    self.appendVisibleText(tail, to: assistantID)
                }
                self.modelState = await self.modelManager.state
                if let directive = parser.parsedDirective {
                    self.lastDirective = directive
                    self.applyDirective(directive, progression: progression, vocabulary: vocabulary)
                    self.markMessageHasGhosts(assistantID, hasGhosts: !self.activeGhosts.isEmpty)
                }
            } catch is CancellationError {
                self.removeEmptyAssistantMessage(assistantID)
            } catch {
                self.modelState = await self.modelManager.state
                self.replaceMessage(
                    assistantID,
                    role: .status,
                    text: error.localizedDescription
                )
            }
            self.isStreaming = false
            self.activeStreamTask = nil
        }
    }

    /// Steer ChordPredictor with a parsed directive and produce voice-led non-destructive ghost proposals.
    public func applyDirective(
        _ directive: SidekickDirective,
        progression: Progression,
        vocabulary: ChordVocabulary
    ) {
        let bias = directive.toSteeringBias(validating: vocabulary)
        let targetBars = directive.targetBars.isEmpty ? [max(1, (progression.regions.count) + 1)] : directive.targetBars
        var proposals: [GhostChordProposal] = []
        var precedingPitches: [Int]? = progression.regions.last?.pitches

        for (index, bar) in targetBars.enumerated() {
            let startStep = max(0, (bar - 1) * MusicDefaults.stepsPerBar)
            let lengthSteps = MusicDefaults.stepsPerBar

            let chosenChord: Chord
            if index < directive.seedChords.count,
               let parsed = Self.parseSeedChord(directive.seedChords[index], vocabulary: vocabulary) {
                chosenChord = parsed
            } else {
                let ranked = (try? predictor?.steeredSuggestions(
                    in: progression,
                    at: startStep,
                    bias: bias,
                    limit: 3
                )) ?? []
                guard let best = ranked.first else { continue }
                chosenChord = best.chord
            }

            let voiced = (try? solver.solve([chosenChord], vocabulary: vocabulary, preceding: precedingPitches).first)
                ?? []
            guard !voiced.isEmpty else { continue }
            precedingPitches = voiced
            let reason = directive.sectionHint.map { "\($0) suggestion" } ?? "coda suggestion"
            proposals.append(
                GhostChordProposal(
                    startStep: startStep,
                    lengthSteps: lengthSteps,
                    chord: chosenChord,
                    pitches: voiced,
                    reason: reason
                )
            )
        }
        activeGhosts = proposals
    }

    public func dismissAllGhosts() {
        activeGhosts = []
    }

    public func dismissGhost(id: UUID) {
        activeGhosts.removeAll { $0.id == id }
    }

    /// Any user edit overlapping a ghost region dismisses that ghost (SPEC §14.4).
    public func dismissGhosts(overlapping startStep: Int, lengthSteps: Int) {
        let endStep = startStep + max(1, lengthSteps)
        activeGhosts.removeAll { ghost in
            ghost.startStep < endStep && ghost.endStep > startStep
        }
    }

    public func clearConversation() {
        cancelStreaming()
        messages = []
        activeGhosts = []
        lastDirective = nil
    }

    private func appendVisibleText(_ delta: String, to id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].text.append(delta)
    }

    private func markMessageHasGhosts(_ id: UUID, hasGhosts: Bool) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].hasDirectiveGhosts = hasGhosts
    }

    private func replaceMessage(_ id: UUID, role: SidekickMessage.Role, text: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx] = SidekickMessage(id: id, role: role, text: text)
    }

    private func removeEmptyAssistantMessage(_ id: UUID) {
        messages.removeAll { $0.id == id && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public static func parseSeedChord(_ symbol: String, vocabulary: ChordVocabulary) -> Chord? {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        let mainPart = parts[0]
        let bassPart = parts.count > 1 ? parts[1] : nil

        guard let (rootPC, suffixStart) = parsePitchClassPrefix(mainPart) else { return nil }
        let suffix = String(mainPart[suffixStart...])
        let slashBass = bassPart.flatMap { parsePitchClassPrefix($0)?.0 }

        if let exact = vocabulary.qualities.first(where: { $0.symbol.caseInsensitiveCompare(suffix) == .orderedSame || $0.id.caseInsensitiveCompare(suffix) == .orderedSame }) {
            return try? Chord(root: rootPC, qualityID: exact.id, slashBass: slashBass)
        }
        return nil
    }

    private static func parsePitchClassPrefix(_ text: String) -> (Int, String.Index)? {
        guard let first = text.first else { return nil }
        let base: Int
        switch first.uppercased() {
        case "C": base = 0
        case "D": base = 2
        case "E": base = 4
        case "F": base = 5
        case "G": base = 7
        case "A": base = 9
        case "B": base = 11
        default: return nil
        }
        var nextIdx = text.index(after: text.startIndex)
        var pc = base
        if nextIdx < text.endIndex {
            let acc = text[nextIdx]
            if acc == "#" || acc == "♯" {
                pc = (pc + 1) % 12
                nextIdx = text.index(after: nextIdx)
            } else if acc == "b" || acc == "♭" {
                pc = (pc + 11) % 12
                nextIdx = text.index(after: nextIdx)
            }
        }
        return (pc, nextIdx)
    }
}
