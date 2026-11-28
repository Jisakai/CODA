import Foundation
import Observation
import AVFoundation
import CodaMusic
import CodaNative

public enum AudioSessionError: Error { case unavailable, capacity, invalidPlan }

/// Control-side tuning only; no control task schedules musical note timing.
public enum TransportConfiguration {
    public static let auditionSeconds = 0.8
    public static let pendingControls = 64
    public static let retryNanoseconds: UInt64 = 2_000_000
}

private final class NativePlan {
    let pointer = UnsafeMutablePointer<CodaPlan>.allocate(capacity: 1)
    init() { pointer.initialize(to: CodaPlan()) }
    deinit { pointer.deinitialize(count: 1); pointer.deallocate() }
}

// NotificationCenter retains observer blocks (and object filters). Remove tokens
// on suspension AND owner destruction, including sessions dropped without close.
private final class AudioObservationTokens {
    var values: [NSObjectProtocol] = []
    func removeAll() {
        for token in values { NotificationCenter.default.removeObserver(token) }
        values.removeAll()
    }
    deinit { removeAll() }
}

@MainActor
private struct PreparedPlan {
    let native: NativePlan?
    let performance: NativePerformancePlan?
    let source: PerformanceCycleSource?
    let playbackRevision: UInt64
    let positionRevision: UInt64
    let playing: Bool
    let step: Int
}

/// An additional user-added synth/plugin layer (DSP slots 3..<12) so users can
/// overlay multiple Chord, Bass, or Melody synths simultaneously.
public struct ExtraLayerTrack: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public let kind: MusicLayer
    public let dspSlot: Int
    public var preset: UInt8
    public var wobble: Float
    public var warmth: Float
    public var cutoff: Float
    public var resonance: Float
    public var shape: Float
    public var detune: Float
    public var glide: Float
    public var level: Float
    public var muted: Bool
    public var pluginID: String?
    public var notes: [RollNote]

    public var layerControls: CodaLayerControls {
        var lc = CodaLayerControls()
        lc.wobble = wobble
        lc.warmth = warmth
        lc.cutoff = cutoff
        lc.resonance = resonance
        lc.shape = shape
        lc.detune = detune
        lc.glide = glide
        lc.level = level
        lc.preset = preset
        lc.muted = muted ? 1 : 0
        return lc
    }

    public mutating func apply(_ controls: CodaLayerControls) {
        wobble = controls.wobble
        warmth = controls.warmth
        cutoff = controls.cutoff
        resonance = controls.resonance
        shape = controls.shape
        detune = controls.detune
        glide = controls.glide
        level = controls.level
        preset = controls.preset
        muted = controls.muted != 0
    }
}

@MainActor @Observable
public final class MusicSession {
    public let vocabulary: ChordVocabulary
    public let solver = VoiceLeadingSolver()
    public let suggestions = RuleBasedChordSuggestions()
    public let predictor: CoreMLChordPredictor
    public let pluginHost = PluginHostManager()
    public private(set) var key: MusicalKey = MusicDefaults.key
    public private(set) var editor: ProgressionEditor
    public private(set) var patterns: PatternArrangement
    public private(set) var bassTrack: BassTrack = .empty
    public private(set) var melodyTrack: MelodyTrack = .empty
    public private(set) var extraLayers: [ExtraLayerTrack] = []
    public private(set) var activeExtraLayerID: String? = nil
    public private(set) var mixerControls: CodaMixerControls
    public private(set) var projectID: String = UUID().uuidString
    public private(set) var projectName: String = "Untitled Sketch"
    public private(set) var projectCreatedAt: Date = Date()
    public private(set) var abSnapshot: ProjectABSnapshot?
    public private(set) var showingSnapshotB: Bool = false

    private struct SessionStateSnapshot {
        let progression: Progression
        let patterns: PatternArrangement
        let bassTrack: BassTrack
        let melodyTrack: MelodyTrack
        let key: MusicalKey
        let loop: LoopSpan
    }

    private enum HistoryEntry {
        case chord(bassBefore: BassTrack, bassAfter: BassTrack)
        case pattern(PatternArrangement, PatternArrangement)
        case bass(BassTrack, BassTrack)
        case melody(MelodyTrack, MelodyTrack)
        case full(before: SessionStateSnapshot, after: SessionStateSnapshot, usesEditorHistory: Bool)
    }

    private var undoHistory: [HistoryEntry] = []
    private var redoHistory: [HistoryEntry] = []
    public var canUndo: Bool { !undoHistory.isEmpty }
    public var canRedo: Bool { !redoHistory.isEmpty }
    public private(set) var tempo = MusicDefaults.tempo
    public private(set) var loop: LoopSpan
    public private(set) var looping = true
    public private(set) var playing = false
    public private(set) var renderedPlaying = false
    /// Last explicit span-relative scrub/stop position, retained without hardware.
    public private(set) var requestedStep = 0
    @ObservationIgnored private var playbackIntent = false
    @ObservationIgnored private var playbackRevision: UInt64 = 0
    @ObservationIgnored private var positionRevision: UInt64 = 0
    public private(set) var error: String?
    public private(set) var available = false
    public private(set) var controls = CodaControls()
    @ObservationIgnored private let audio = CodaAudioAdapter()
    @ObservationIgnored private let offline: Bool
    @ObservationIgnored private var desiredPlan: PreparedPlan?
    @ObservationIgnored private var publishedPlan: PreparedPlan?
    @ObservationIgnored private var publishedGeneration: UInt64 = 0
    @ObservationIgnored private var legacyUnconsumed: [UInt64] = []
    @ObservationIgnored private var activeSource: PerformanceCycleSource?
    @ObservationIgnored private var activeGeneration: UInt64 = 0
    @ObservationIgnored private var pendingControls: [CodaControls] = []
    @ObservationIgnored private var pendingMixerControls: [CodaMixerControls] = []
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private let audioObservers = AudioObservationTokens()
    @ObservationIgnored private(set) var lifecycleEpoch = UUID()
    @ObservationIgnored private var auditionPreviewOwner: UUID?
    @ObservationIgnored private var pendingPreviewStop: UUID?
    /// Read-only UI epoch; delayed previews must not reopen a suspended engine.
    public var previewEpoch: UUID { lifecycleEpoch }

    // Exposed internally only for production lifecycle-routing tests.
    var configurationOwner: NSObject? { audio.configurationOwner }

    public init(vocabulary: ChordVocabulary, offline: Bool = false) throws {
        self.vocabulary = vocabulary
        self.offline = offline
        self.predictor = CoreMLChordPredictor(vocabulary: vocabulary, key: MusicDefaults.key)
        self.editor = ProgressionEditor(try Progression(vocabulary: vocabulary))
        self.patterns = try PatternArrangement()
        self.loop = try LoopSpan()
        self.mixerControls = coda_dsp_default_mixer_controls()
        self.mixerControls.tempo_bpm = Float(MusicDefaults.tempo)
        coda_dsp_default_controls(0, &controls)
        syncLegacyControlsFromMixer()
    }

    /// Lazy output-only startup. Ordinary empty launch does not start hardware.
    public func activate() throws {
        guard !available else { return }
        do {
            try audio.open(offline: offline)
            let plan = try preparePlan()
            try audio.start()
            available = true
            if pendingControls.isEmpty && pendingMixerControls.isEmpty {
                pendingMixerControls.append(mixerControls)
            }
            for track in extraLayers {
                publishTrackControlsToNative(track)
            }
            commitPlan(plan)
            observeAudioLifecycle()
            pump()
            error = nil
        } catch {
            let savedPlayback = playbackRevision, savedPosition = positionRevision
            let savedPlaying = playing, savedIntent = playbackIntent, savedStep = requestedStep
            // Failed startup must retain unpublished preset/mute edges for retry.
            let savedControls = pendingControls
            let savedMixer = pendingMixerControls
            suspend()
            pendingControls = savedControls
            pendingMixerControls = savedMixer
            playbackRevision = savedPlayback; positionRevision = savedPosition
            playing = savedPlaying; playbackIntent = savedIntent; requestedStep = savedStep
            self.error = String(describing: error)
            throw error
        }
    }

    /// Called for background, interruption and route/configuration changes.
    /// Reopening always prepares at actual format and recompiles off render.
    public func suspend() {
        lifecycleEpoch = UUID()
        auditionPreviewOwner = nil
        pendingPreviewStop = nil
        audioObservers.removeAll()
        retry?.cancel(); retry = nil
        desiredPlan = nil; publishedPlan = nil; publishedGeneration = 0
        legacyUnconsumed.removeAll()
        activeSource = nil; activeGeneration = 0
        pendingControls.removeAll()
        pendingMixerControls.removeAll()
        audio.close()
        available = false; playing = false; renderedPlaying = false
        // Reopen creates a fresh native epoch; retire all old commands.
        playbackIntent = false; playbackRevision = 0; positionRevision = 0; requestedStep = 0
    }

    public func play() throws {
        if !available { try changePlayback(playing: true); try activate() }
        else { try changePlayback(playing: true) }
    }
    public func pause() throws { try changePlayback(playing: false) }
    public func stop() throws { try changePlayback(playing: false, seek: 0) }
    public func restart() throws {
        if !available { try changePlayback(playing: true, seek: 0); try activate() }
        else { try changePlayback(playing: true, seek: 0) }
    }
    private func changePlayback(playing value: Bool, seek: Int? = nil) throws {
        let plan = try preparePlan(playing: value, seek: seek)
        commitPlan(plan)
    }
    public func seek(step: Int) throws {
        guard (0..<editor.progression.totalSteps).contains(step) else { throw MusicError.invalidSpan }
        let span = try playbackSpan()
        try schedule(seek: min(max(0, step - span.start), span.length - 1))
    }
    public func setTempo(_ value: Double) throws {
        guard value.isFinite, (30...300).contains(value) else { throw MusicError.invalidTempo }
        var next = controls; next.tempo_bpm = Float(value)
        let plan = try preparePlan(tempo: value)
        try validateControls(next)
        // No fallible work or publication follows the first state mutation.
        tempo = value
        mixerControls.tempo_bpm = Float(value)
        enqueueControls(next)
        commitPlan(plan)
    }
    public func setLoop(_ span: LoopSpan, enabled: Bool) throws {
        guard span.end <= editor.progression.totalSteps else { throw MusicError.invalidSpan }
        let plan = try preparePlan(loop: span, looping: enabled)
        loop = span; looping = enabled
        commitPlan(plan)
    }
    public func edit(_ edits: [ProgressionEdit]) throws {
        var candidate = editor
        try candidate.apply(edits, vocabulary: vocabulary, solver: solver)
        guard candidate.progression != editor.progression else { return }
        let nextBass = reconciledBass(from: editor.progression, to: candidate.progression)
        let resizedPatterns = try PatternArrangement(
            barCount: candidate.progression.totalSteps / MusicDefaults.stepsPerBar,
            regions: patterns.regions
        )
        let plan = try preparePlan(progression: candidate.progression, arrangement: resizedPatterns, bass: nextBass)
        let previousBass = bassTrack
        editor = candidate
        patterns = resizedPatterns
        bassTrack = nextBass
        undoHistory.append(.chord(bassBefore: previousBass, bassAfter: nextBass))
        redoHistory.removeAll()
        commitPlan(plan)
    }
    public func extendArrangement(through end: Int) throws {
        var candidate = editor
        try candidate.extendExtent(through: end, vocabulary: vocabulary)
        guard candidate.progression.totalSteps != editor.progression.totalSteps else { return }
        let next = try PatternArrangement(barCount: candidate.progression.totalSteps / MusicDefaults.stepsPerBar,
            regions: patterns.regions)
        let plan = try preparePlan(progression: candidate.progression, arrangement: next)
        editor = candidate; patterns = next; commitPlan(plan)
    }
    public func editPatterns(_ edits: [PatternEdit]) throws {
        let next = try PatternEditor(patterns).preview(edits)
        guard next != patterns else { return }
        let plan = try preparePlan(arrangement: next)
        undoHistory.append(.pattern(patterns, next)); redoHistory.removeAll()
        patterns = next; commitPlan(plan)
    }

    // MARK: - 3-Layer Tracks & Mixer Controls

    public func layerControls(for layer: MusicLayer) -> CodaLayerControls {
        switch layer {
        case .chords: return mixerControls.layers.0
        case .bass: return mixerControls.layers.1
        case .melody: return mixerControls.layers.2
        }
    }

    public func setLayerControls(_ controls: CodaLayerControls, for layer: MusicLayer) {
        let floats = [controls.wobble, controls.warmth, controls.cutoff, controls.resonance,
                      controls.shape, controls.detune, controls.glide, controls.level]
        guard floats.allSatisfy({ $0.isFinite }), controls.preset <= 2 else { return }
        var next = mixerControls
        switch layer {
        case .chords: next.layers.0 = controls
        case .bass: next.layers.1 = controls
        case .melody: next.layers.2 = controls
        }
        applyMixerControls(next)
    }

    public func setSharedFX(delay: Float, reverb: Float) {
        setSharedFX(chorus: mixerControls.chorus_amount, delay: delay, reverb: reverb)
    }

    public func setSharedFX(chorus: Float, delay: Float, reverb: Float) {
        guard chorus.isFinite, delay.isFinite, reverb.isFinite else { return }
        var next = mixerControls
        next.chorus_amount = min(1, max(0, chorus))
        next.delay_amount = min(1, max(0, delay))
        next.reverb_amount = min(1, max(0, reverb))
        applyMixerControls(next)
    }

    // MARK: - Multi-Layer Extra Tracks (DSP slots 3..<12)

    @discardableResult
    public func addExtraLayer(kind: MusicLayer, name: String? = nil) -> ExtraLayerTrack? {
        let usedSlots = Set(extraLayers.map(\.dspSlot))
        guard let freeSlot = (Int(CODA_LAYER_COUNT.rawValue)..<Int(CODA_MAX_TRACKS)).first(where: { !usedSlots.contains($0) }) else {
            return nil
        }
        let sameKindCount = extraLayers.filter { $0.kind == kind }.count + 2
        let baseName: String
        switch kind {
        case .chords: baseName = "Chords \(sameKindCount)"
        case .bass: baseName = "Bass \(sameKindCount)"
        case .melody: baseName = "Melody \(sameKindCount)"
        }
        let defaults = layerControls(for: kind)
        let track = ExtraLayerTrack(
            id: UUID().uuidString,
            name: name ?? baseName,
            kind: kind,
            dspSlot: freeSlot,
            preset: defaults.preset,
            wobble: defaults.wobble,
            warmth: defaults.warmth,
            cutoff: defaults.cutoff,
            resonance: defaults.resonance,
            shape: defaults.shape,
            detune: defaults.detune,
            glide: defaults.glide,
            level: defaults.level,
            muted: false,
            pluginID: nil,
            notes: []
        )
        extraLayers.append(track)
        activeExtraLayerID = track.id
        publishTrackControlsToNative(track)
        return track
    }

    public func removeExtraLayer(id: String) {
        guard let idx = extraLayers.firstIndex(where: { $0.id == id }) else { return }
        var removed = extraLayers.remove(at: idx)
        removed.muted = true
        publishTrackControlsToNative(removed)
        if activeExtraLayerID == id { activeExtraLayerID = nil }
        try? schedule()
    }

    public func selectExtraLayer(id: String?) {
        if let id, extraLayers.contains(where: { $0.id == id }) {
            activeExtraLayerID = id
        } else {
            activeExtraLayerID = nil
        }
    }

    public func setExtraLayerControls(_ controls: CodaLayerControls, for id: String) {
        guard let idx = extraLayers.firstIndex(where: { $0.id == id }) else { return }
        let floats = [controls.wobble, controls.warmth, controls.cutoff, controls.resonance,
                      controls.shape, controls.detune, controls.glide, controls.level]
        guard floats.allSatisfy({ $0.isFinite }), controls.preset <= 2 else { return }
        extraLayers[idx].apply(controls)
        publishTrackControlsToNative(extraLayers[idx])
    }

    public func setExtraLayerMuted(_ muted: Bool, for id: String) {
        guard let idx = extraLayers.firstIndex(where: { $0.id == id }) else { return }
        extraLayers[idx].muted = muted
        publishTrackControlsToNative(extraLayers[idx])
    }

    public func setExtraLayerNotes(_ notes: [RollNote], for id: String) {
        guard let idx = extraLayers.firstIndex(where: { $0.id == id }) else { return }
        extraLayers[idx].notes = notes
        try? schedule()
    }

    public func setExtraLayerPlugin(_ pluginID: String?, for id: String) {
        guard let idx = extraLayers.firstIndex(where: { $0.id == id }) else { return }
        extraLayers[idx].pluginID = pluginID
    }

    private func publishTrackControlsToNative(_ track: ExtraLayerTrack) {
        guard available else { return }
        _ = audio.publish(trackControls: track.layerControls,
                          forTrack: UInt8(track.dspSlot),
                          eqProfile: track.kind.nativeIndex)
    }

    public func isLayerMuted(_ layer: MusicLayer) -> Bool {
        layerControls(for: layer).muted != 0
    }

    public func setLayerMuted(_ muted: Bool, for layer: MusicLayer) {
        var lc = layerControls(for: layer)
        lc.muted = muted ? 1 : 0
        setLayerControls(lc, for: layer)
    }

    public func soloLayer(_ layer: MusicLayer) {
        var next = mixerControls
        next.layers.0.muted = layer == .chords ? 0 : 1
        next.layers.1.muted = layer == .bass ? 0 : 1
        next.layers.2.muted = layer == .melody ? 0 : 1
        applyMixerControls(next)
    }

    public func unmuteAllLayers() {
        var next = mixerControls
        next.layers.0.muted = 0
        next.layers.1.muted = 0
        next.layers.2.muted = 0
        applyMixerControls(next)
    }

    public func audition(pitches: [Int], layer: MusicLayer) {
        let sorted = Array(Set(pitches.filter { (0...127).contains($0) })).sorted()
        guard sorted.count <= 12 else { return }
        do { try activate() } catch { return }
        let values = sorted.map(UInt8.init)
        let result = values.withUnsafeBufferPointer {
            audio.audition(layer: layer.nativeIndex, pitches: $0.baseAddress,
                           count: UInt32($0.count),
                           frames: UInt32(audio.sampleRate * TransportConfiguration.auditionSeconds))
        }
        if result == 1 {
            auditionPreviewOwner = nil
            pendingPreviewStop = nil
        }
    }

    public func setBassTrack(_ track: BassTrack) {
        guard track != bassTrack else { return }
        do {
            let plan = try preparePlan(bass: track)
            undoHistory.append(.bass(bassTrack, track))
            redoHistory.removeAll()
            bassTrack = track
            commitPlan(plan)
        } catch {
            self.error = String(describing: error)
        }
    }

    public func setMelodyTrack(_ track: MelodyTrack) {
        guard track != melodyTrack else { return }
        do {
            let plan = try preparePlan(melody: track)
            undoHistory.append(.melody(melodyTrack, track))
            redoHistory.removeAll()
            melodyTrack = track
            commitPlan(plan)
        } catch {
            self.error = String(describing: error)
        }
    }

    public func clearLayer(_ layer: MusicLayer) {
        switch layer {
        case .bass:
            setBassTrack(.empty)
        case .melody:
            setMelodyTrack(.empty)
        case .chords:
            guard !editor.progression.regions.isEmpty else { return }
            do {
                var candidate = editor
                let deletes = editor.progression.regions.map { ProgressionEdit.delete(id: $0.id) }
                try candidate.apply(deletes, vocabulary: vocabulary, solver: solver)
                let plan = try preparePlan(progression: candidate.progression)
                editor = candidate
                undoHistory.append(.chord(bassBefore: bassTrack, bassAfter: bassTrack))
                redoHistory.removeAll()
                commitPlan(plan)
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    // MARK: - Musical QoL (Key, Transpose, + Bar, A/B, Ghost Chords)

    public func setKey(_ key: MusicalKey) throws {
        self.key = key
        self.predictor.key = key
    }

    public func switchRelativeKey() throws {
        let next: MusicalKey
        switch key.mode {
        case .major:
            next = MusicalKey(tonic: key.tonic - 3, mode: .naturalMinor)
        case .naturalMinor:
            next = MusicalKey(tonic: key.tonic + 3, mode: .major)
        }
        try setKey(next)
    }

    public func transposeAll(semitones: Int) throws {
        guard semitones != 0 else { return }
        let before = currentSnapshot()
        let nextKey = MusicalKey(tonic: key.tonic + semitones, mode: key.mode)

        var candidate = editor
        let hasRegions = !editor.progression.regions.isEmpty
        if hasRegions {
            let deltaPC = (semitones % 12 + 12) % 12
            let replacements: [ProgressionEdit] = try editor.progression.regions.map { region in
                let newRoot = (region.chord.root + deltaPC) % 12
                let newSlash = region.chord.slashBass.map { ($0 + deltaPC) % 12 }
                let newChord = try Chord(root: newRoot, qualityID: region.chord.qualityID, slashBass: newSlash)
                let newNotes = try region.notes.map { note in
                    try RollNote(
                        id: note.id,
                        startTick: note.startTick,
                        durationTicks: note.durationTicks,
                        pitch: note.pitch + semitones,
                        velocity: note.velocity,
                        slide: note.slide
                    )
                }
                let newPitches = Array(Set(newNotes.map(\.pitch))).sorted()
                let updated = try ChordRegion(
                    id: region.id,
                    chord: newChord,
                    start: region.start,
                    length: region.length,
                    pitches: newPitches,
                    notes: newNotes,
                    detectionUncertain: region.detectionUncertain
                )
                return .replace(updated)
            }
            try candidate.apply(replacements, vocabulary: vocabulary, solver: solver)
        }

        let nextBass = try bassTrack.transposing(semitones: semitones)
        let nextMelody = try melodyTrack.transposing(semitones: semitones)
        let plan = try preparePlan(progression: candidate.progression, bass: nextBass, melody: nextMelody)

        let after = SessionStateSnapshot(
            progression: candidate.progression,
            patterns: patterns,
            bassTrack: nextBass,
            melodyTrack: nextMelody,
            key: nextKey,
            loop: loop
        )

        key = nextKey
        predictor.key = nextKey
        editor = candidate
        bassTrack = nextBass
        melodyTrack = nextMelody
        undoHistory.append(.full(before: before, after: after, usesEditorHistory: hasRegions))
        redoHistory.removeAll()
        commitPlan(plan)
    }

    public func duplicateBar(at barIndex: Int) throws {
        let totalBars = editor.progression.totalSteps / MusicDefaults.stepsPerBar
        guard barIndex >= 0, barIndex < totalBars else { throw MusicError.invalidSpan }
        let before = currentSnapshot()

        let barSteps = MusicDefaults.stepsPerBar
        let barStartStep = barIndex * barSteps
        let barEndStep = barStartStep + barSteps
        let barTicks = barSteps * MusicDefaults.ticksPerStep
        let barStartTick = barStartStep * MusicDefaults.ticksPerStep
        let barEndTick = barEndStep * MusicDefaults.ticksPerStep
        let newTotalBars = totalBars + 1
        let newTotalSteps = newTotalBars * barSteps

        // 1. Chords
        var nextRegions: [ChordRegion] = []
        for region in editor.progression.regions {
            if region.end <= barStartStep {
                nextRegions.append(region)
            } else if region.start >= barEndStep {
                nextRegions.append(try ChordRegion(
                    id: region.id,
                    chord: region.chord,
                    start: region.start + barSteps,
                    length: region.length,
                    pitches: region.pitches,
                    notes: region.notes,
                    detectionUncertain: region.detectionUncertain
                ))
            } else if region.start >= barStartStep && region.end <= barEndStep {
                nextRegions.append(region)
                let dupID = "\(region.id)-dup-\(UUID().uuidString.prefix(8))"
                let dupNotes = try region.notes.map { note in
                    try RollNote(
                        id: "\(dupID)-\(note.pitch)-\(note.startTick)",
                        startTick: note.startTick,
                        durationTicks: note.durationTicks,
                        pitch: note.pitch,
                        velocity: note.velocity,
                        slide: note.slide
                    )
                }
                nextRegions.append(try ChordRegion(
                    id: dupID,
                    chord: region.chord,
                    start: region.start + barSteps,
                    length: region.length,
                    pitches: region.pitches,
                    notes: dupNotes,
                    detectionUncertain: region.detectionUncertain
                ))
            } else {
                // Region spans across a boundary of the duplicated bar: extend by 1 bar.
                let oldEndTicks = region.length * MusicDefaults.ticksPerStep
                let newLength = region.length + barSteps
                let newEndTicks = newLength * MusicDefaults.ticksPerStep
                let stretchedNotes = try region.notes.map { note in
                    try RollNote(
                        id: note.id,
                        startTick: note.startTick,
                        durationTicks: note.endTick == oldEndTicks ? (newEndTicks - note.startTick) : note.durationTicks,
                        pitch: note.pitch,
                        velocity: note.velocity,
                        slide: note.slide
                    )
                }
                nextRegions.append(try ChordRegion(
                    id: region.id,
                    chord: region.chord,
                    start: region.start,
                    length: newLength,
                    pitches: region.pitches,
                    notes: stretchedNotes,
                    detectionUncertain: region.detectionUncertain
                ))
            }
        }
        let nextProgression = try Progression(totalSteps: newTotalSteps, regions: nextRegions, vocabulary: vocabulary)

        // 2. Bass
        var nextBassNotes: [BassNote] = []
        for note in bassTrack.notes {
            if note.endTick <= barStartTick {
                nextBassNotes.append(note)
            } else if note.startTick >= barEndTick {
                nextBassNotes.append(try BassNote(
                    id: note.id,
                    startTick: note.startTick + barTicks,
                    durationTicks: note.durationTicks,
                    pitch: note.pitch,
                    velocity: note.velocity,
                    slide: note.slide,
                    provenance: note.provenance,
                    userEdited: note.userEdited
                ))
            } else if note.startTick >= barStartTick && note.endTick <= barEndTick {
                nextBassNotes.append(note)
                nextBassNotes.append(try BassNote(
                    id: UUID().uuidString,
                    startTick: note.startTick + barTicks,
                    durationTicks: note.durationTicks,
                    pitch: note.pitch,
                    velocity: note.velocity,
                    slide: note.slide,
                    provenance: note.provenance,
                    userEdited: note.userEdited
                ))
            } else {
                nextBassNotes.append(try BassNote(
                    id: note.id,
                    startTick: note.startTick,
                    durationTicks: note.durationTicks + barTicks,
                    pitch: note.pitch,
                    velocity: note.velocity,
                    slide: note.slide,
                    provenance: note.provenance,
                    userEdited: note.userEdited
                ))
            }
        }
        let nextBass = try BassTrack(notes: nextBassNotes)

        // 3. Melody
        var nextMelodyNotes: [MelodyNote] = []
        for note in melodyTrack.notes {
            if note.endTick <= barStartTick {
                nextMelodyNotes.append(note)
            } else if note.startTick >= barEndTick {
                nextMelodyNotes.append(try MelodyNote(
                    id: note.id,
                    startTick: note.startTick + barTicks,
                    durationTicks: note.durationTicks,
                    pitch: note.pitch,
                    velocity: note.velocity,
                    slide: note.slide,
                    nudgeTicks: note.nudgeTicks
                ))
            } else if note.startTick >= barStartTick && note.endTick <= barEndTick {
                nextMelodyNotes.append(note)
                nextMelodyNotes.append(try MelodyNote(
                    id: UUID().uuidString,
                    startTick: note.startTick + barTicks,
                    durationTicks: note.durationTicks,
                    pitch: note.pitch,
                    velocity: note.velocity,
                    slide: note.slide,
                    nudgeTicks: note.nudgeTicks
                ))
            } else {
                nextMelodyNotes.append(try MelodyNote(
                    id: note.id,
                    startTick: note.startTick,
                    durationTicks: note.durationTicks + barTicks,
                    pitch: note.pitch,
                    velocity: note.velocity,
                    slide: note.slide,
                    nudgeTicks: note.nudgeTicks
                ))
            }
        }
        let nextMelody = try MelodyTrack(notes: nextMelodyNotes)

        // 4. Patterns
        let nextPatternRegions: [PatternRegion] = try patterns.regions.map { region in
            if region.range.end <= barIndex {
                return region
            } else if region.range.start >= barIndex + 1 {
                let shifted = try PatternBarRange(start: region.range.start + 1, length: region.range.length)
                return try PatternRegion(id: region.id, range: shifted, slots: region.slots, settings: region.settings)
            } else {
                let extended = try PatternBarRange(start: region.range.start, length: region.range.length + 1)
                return try PatternRegion(id: region.id, range: extended, slots: region.slots, settings: region.settings)
            }
        }
        let nextPatterns = try PatternArrangement(barCount: newTotalBars, regions: nextPatternRegions)

        let plan = try preparePlan(
            progression: nextProgression,
            arrangement: nextPatterns,
            bass: nextBass,
            melody: nextMelody
        )

        let after = SessionStateSnapshot(
            progression: nextProgression,
            patterns: nextPatterns,
            bassTrack: nextBass,
            melodyTrack: nextMelody,
            key: key,
            loop: loop
        )

        editor = ProgressionEditor(nextProgression)
        patterns = nextPatterns
        bassTrack = nextBass
        melodyTrack = nextMelody
        undoHistory.append(.full(before: before, after: after, usesEditorHistory: false))
        redoHistory.removeAll()
        commitPlan(plan)
    }

    public func captureABSnapshot() {
        abSnapshot = makeProjectDocument().captureABSnapshot(label: "A")
        showingSnapshotB = false
    }

    public func toggleABSnapshot() throws {
        guard let target = abSnapshot else { return }
        let current = makeProjectDocument().captureABSnapshot(label: showingSnapshotB ? "B" : "A")

        let progression = try Progression(
            totalSteps: target.arrangementTotalSteps,
            regions: target.chordRegions,
            vocabulary: vocabulary
        )
        let bass = try BassTrack(notes: target.bassNotes)
        let melody = try MelodyTrack(notes: target.melodyNotes)
        let nextPatterns = try PatternArrangement(
            barCount: progression.totalSteps / MusicDefaults.stepsPerBar,
            regions: target.patternArrangement.regions
        )
        let nextMixer = Self.mixerControls(from: target.synthState, tempo: target.tempo)
        let plan = try preparePlan(
            progression: progression,
            arrangement: nextPatterns,
            bass: bass,
            melody: melody,
            tempo: target.tempo,
            loop: target.loopSpan,
            looping: looping
        )

        tempo = target.tempo
        key = target.key
        predictor.key = target.key
        loop = target.loopSpan
        editor = ProgressionEditor(progression)
        patterns = nextPatterns
        bassTrack = bass
        melodyTrack = melody
        abSnapshot = current
        showingSnapshotB.toggle()
        applyMixerControls(nextMixer)
        commitPlan(plan)
    }

    public func acceptGhostChords(_ proposals: [(startStep: Int, lengthSteps: Int, chord: Chord, pitches: [Int])]) throws {
        guard !proposals.isEmpty else { return }
        var edits: [ProgressionEdit] = []
        var removedIDs = Set<String>()

        for proposal in proposals {
            let pStart = proposal.startStep
            let pEnd = pStart + proposal.lengthSteps
            for existing in editor.progression.regions where !removedIDs.contains(existing.id) {
                if existing.start < pEnd && existing.end > pStart {
                    removedIDs.insert(existing.id)
                    edits.append(.delete(id: existing.id))
                }
            }
            let region = try ChordRegion(
                id: UUID().uuidString,
                chord: proposal.chord,
                start: pStart,
                length: proposal.lengthSteps,
                pitches: proposal.pitches
            )
            edits.append(.add(region))
        }

        // Delegates to edit(_:) for atomic 1-step undo + BassFollower sync; never touches melodyTrack.
        try edit(edits)
    }

    // MARK: - Project Document Persistence & MIDI Export

    public func makeProjectDocument(viewport: ViewportState = ViewportState()) -> CodaProjectDocument {
        CodaProjectDocument(
            schemaVersion: CodaProjectDocument.currentSchemaVersion,
            id: projectID,
            name: projectName,
            createdAt: projectCreatedAt,
            modifiedAt: Date(),
            tempo: tempo,
            key: key,
            loopSpan: loop,
            looping: looping,
            arrangementTotalSteps: editor.progression.totalSteps,
            chordRegions: editor.progression.regions,
            bassNotes: bassTrack.notes,
            melodyNotes: melodyTrack.notes,
            patternArrangement: patterns,
            synthState: Self.synthState(from: mixerControls),
            viewport: viewport,
            abSnapshot: abSnapshot
        )
    }

    public func loadProjectDocument(_ document: CodaProjectDocument) throws {
        guard document.tempo.isFinite, (30...300).contains(document.tempo) else {
            throw MusicError.invalidTempo
        }
        let progression = try document.makeProgression(vocabulary: vocabulary)
        guard document.loopSpan.end <= progression.totalSteps else {
            throw MusicError.invalidSpan
        }
        let bass = try document.makeBassTrack()
        let melody = try document.makeMelodyTrack()
        let nextPatterns = try PatternArrangement(
            barCount: progression.totalSteps / MusicDefaults.stepsPerBar,
            regions: document.patternArrangement.regions
        )
        let nextMixer = Self.mixerControls(from: document.synthState, tempo: document.tempo)
        let plan = try preparePlan(
            progression: progression,
            arrangement: nextPatterns,
            bass: bass,
            melody: melody,
            tempo: document.tempo,
            loop: document.loopSpan,
            looping: document.looping,
            seek: 0
        )

        projectID = document.id
        projectName = document.name
        projectCreatedAt = document.createdAt
        tempo = document.tempo
        key = document.key
        predictor.key = document.key
        loop = document.loopSpan
        looping = document.looping
        editor = ProgressionEditor(progression)
        patterns = nextPatterns
        bassTrack = bass
        melodyTrack = melody
        abSnapshot = document.abSnapshot
        showingSnapshotB = false
        undoHistory.removeAll()
        redoHistory.removeAll()
        applyMixerControls(nextMixer)
        commitPlan(plan)
    }

    public func exportMIDI(includeMutedLayers: Bool = false) throws -> Data {
        let options = MIDIExportOptions(
            mutedLayers: currentMutedLayers,
            respectMutes: !includeMutedLayers
        )
        return try MIDIExporter.export(
            progression: editor.progression,
            patternArrangement: patterns,
            bass: bassTrack,
            melody: melodyTrack,
            tempo: tempo,
            key: key,
            projectName: projectName,
            options: options
        )
    }

    /// Bounces a saved project document offline through the real CodaDSP audio engine into a 24-bit stereo RIFF WAV.
    public static func exportWAV(document: CodaProjectDocument, vocabulary: ChordVocabulary, tailSeconds: Double = 1.5) throws -> Data {
        let offlineSession = try MusicSession(vocabulary: vocabulary, offline: true)
        defer { offlineSession.audio.close() }
        try offlineSession.loadProjectDocument(document)
        return try offlineSession.exportWAV(includeMutedLayers: false, tailSeconds: tailSeconds)
    }

    /// Bounces the current session offline through the real CodaDSP audio engine into a 24-bit stereo RIFF WAV.
    public func exportWAV(includeMutedLayers: Bool = false, tailSeconds: Double = 1.5) throws -> Data {
        let doc = makeProjectDocument()
        let offlineSession = try MusicSession(vocabulary: vocabulary, offline: true)
        defer { offlineSession.audio.close() }
        try offlineSession.loadProjectDocument(doc)
        var exportMixer = mixerControls
        if includeMutedLayers {
            exportMixer.chords.muted = 0
            exportMixer.bass.muted = 0
            exportMixer.melody.muted = 0
        }
        offlineSession.applyMixerControls(exportMixer)
        let activeSteps = max(MusicDefaults.stepsPerBar, looping ? loop.length : editor.progression.totalSteps)
        let sr = max(44100.0, offlineSession.audio.sampleRate)
        let secondsPerStep = 60.0 / max(20.0, tempo) / 4.0
        let totalSeconds = Double(activeSteps) * secondsPerStep + max(0.0, tailSeconds)
        let totalFrames = max(512, Int((totalSeconds * sr).rounded(.up)))
        try offlineSession.play()
        offlineSession.pump()

        var interleaved = Data()
        interleaved.reserveCapacity(totalFrames * 2 * MemoryLayout<Float>.size)
        let chunkFrames: UInt32 = 4096
        var remaining = UInt32(totalFrames)
        while remaining > 0 {
            let chunk = min(chunkFrames, remaining)
            let chunkData = try offlineSession.audio.renderOfflineStereoFloat(frames: chunk)
            interleaved.append(chunkData)
            offlineSession.pump()
            remaining -= chunk
        }
        return Self.encodeWAV24Stereo(interleavedFloatData: interleaved, sampleRate: Int(sr.rounded()))
    }

    /// Encodes interleaved stereo Float32 samples into a standard 24-bit PCM RIFF WAVE container.
    public static func encodeWAV24Stereo(interleavedFloatData: Data, sampleRate: Int) -> Data {
        let sampleCount = interleavedFloatData.count / MemoryLayout<Float>.size
        let numChannels: UInt16 = 2
        let bitsPerSample: UInt16 = 24
        let bytesPerSample = Int(bitsPerSample / 8)
        let dataByteCount = UInt32(sampleCount * bytesPerSample)
        let byteRate = UInt32(sampleRate * Int(numChannels) * bytesPerSample)
        let blockAlign = UInt16(Int(numChannels) * bytesPerSample)
        let riffSize = UInt32(36) + dataByteCount

        var wav = Data()
        wav.reserveCapacity(44 + Int(dataByteCount))
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) }
        }

        wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        appendLE(riffSize)
        wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        appendLE(UInt32(16))                             // PCM fmt chunk size
        appendLE(UInt16(1))                              // AudioFormat = 1 (PCM)
        appendLE(numChannels)
        appendLE(UInt32(sampleRate))
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)
        wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        appendLE(dataByteCount)

        interleavedFloatData.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            var bytes = [UInt8](repeating: 0, count: sampleCount * 3)
            let scale: Double = 8_388_607.0 // 2^23 - 1
            for i in 0..<sampleCount {
                let clamped = max(-1.0, min(1.0, Double(floats[i])))
                let int24 = Int32((clamped * scale).rounded())
                let u = UInt32(bitPattern: int24)
                let base = i * 3
                bytes[base] = UInt8(u & 0xFF)
                bytes[base + 1] = UInt8((u >> 8) & 0xFF)
                bytes[base + 2] = UInt8((u >> 16) & 0xFF)
            }
            wav.append(contentsOf: bytes)
        }
        return wav
    }

    // MARK: - Unified Undo / Redo

    public func undo() throws { try moveHistory(undoing: true) }
    public func redo() throws { try moveHistory(undoing: false) }

    private func moveHistory(undoing: Bool) throws {
        guard let entry = (undoing ? undoHistory : redoHistory).last else { return }
        var candidate = editor
        var nextPatterns = patterns
        var nextBass = bassTrack
        var nextMelody = melodyTrack
        var nextKey = key
        var nextLoop = loop

        switch entry {
        case .chord(let bassBefore, let bassAfter):
            guard undoing ? candidate.undo() : candidate.redo() else { throw AudioSessionError.invalidPlan }
            try candidate.extendExtent(through: max(editor.progression.totalSteps, loop.end), vocabulary: vocabulary)
            nextPatterns = try PatternArrangement(
                barCount: candidate.progression.totalSteps / MusicDefaults.stepsPerBar,
                regions: nextPatterns.regions
            )
            nextBass = undoing ? bassBefore : bassAfter

        case .pattern(let before, let after):
            let chosen = undoing ? before : after
            try candidate.extendExtent(through: max(editor.progression.totalSteps, loop.end), vocabulary: vocabulary)
            nextPatterns = try PatternArrangement(
                barCount: candidate.progression.totalSteps / MusicDefaults.stepsPerBar,
                regions: chosen.regions
            )

        case .bass(let before, let after):
            nextBass = undoing ? before : after

        case .melody(let before, let after):
            nextMelody = undoing ? before : after

        case .full(let before, let after, let usesEditorHistory):
            let target = undoing ? before : after
            if usesEditorHistory {
                guard undoing ? candidate.undo() : candidate.redo() else { throw AudioSessionError.invalidPlan }
            } else {
                candidate = ProgressionEditor(target.progression)
            }
            nextLoop = target.loop
            if candidate.progression.totalSteps < nextLoop.end {
                try candidate.extendExtent(through: nextLoop.end, vocabulary: vocabulary)
            }
            nextPatterns = try PatternArrangement(
                barCount: candidate.progression.totalSteps / MusicDefaults.stepsPerBar,
                regions: target.patterns.regions
            )
            nextBass = target.bassTrack
            nextMelody = target.melodyTrack
            nextKey = target.key
        }

        let plan = try preparePlan(
            progression: candidate.progression,
            arrangement: nextPatterns,
            bass: nextBass,
            melody: nextMelody,
            loop: nextLoop
        )

        if undoing { undoHistory.removeLast(); redoHistory.append(entry) }
        else { redoHistory.removeLast(); undoHistory.append(entry) }

        editor = candidate
        patterns = nextPatterns
        bassTrack = nextBass
        melodyTrack = nextMelody
        key = nextKey
        predictor.key = nextKey
        loop = nextLoop
        commitPlan(plan)
    }

    // MARK: - Audition & Legacy Controls

    public func audition(regionID: String) throws { try audition(pitches: editor.audition(id: regionID)) }
    public func audition(chord: Chord) throws {
        try audition(pitches: solver.solve([chord], vocabulary: vocabulary)[0])
    }
    public func audition(pitches: [Int]) throws {
        guard pitches.count <= 12, pitches.allSatisfy({ (0...127).contains($0) }),
              zip(pitches, pitches.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else { throw MusicError.invalidPitches }
        try activate()
        let values = pitches.map(UInt8.init)
        let result = values.withUnsafeBufferPointer {
            audio.audition(pitches: $0.baseAddress, count: UInt32($0.count),
                           frames: UInt32(audio.sampleRate * TransportConfiguration.auditionSeconds))
        }
        guard result == 1 else { throw result == 0 ? AudioSessionError.capacity : AudioSessionError.invalidPlan }
        // A successful explicit audition supersedes any older preview cleanup.
        auditionPreviewOwner = nil
        pendingPreviewStop = nil
    }

    /// UI-only ownership around the existing finite native audition command.
    /// No progression, history, playback intent, or render-path changes.
    public func auditionPreview(chord: Chord, owner: UUID) throws {
        try audition(chord: chord)
        auditionPreviewOwner = owner
    }

    public func cancelAuditionPreview(owner: UUID) {
        guard auditionPreviewOwner == owner, available else { return }
        pendingPreviewStop = owner
        pump()
    }

    public func setControls(_ value: CodaControls) throws {
        try validateControls(value)
        enqueueControls(value)
        syncMixerFromLegacyControls(value)
        if available { pump() }
    }

    private func validateControls(_ value: CodaControls) throws {
        let values = [value.wobble, value.warmth, value.cutoff, value.resonance, value.shape,
                      value.detune, value.glide, value.delay_amount, value.reverb_amount, value.chord_level]
        guard values.allSatisfy({ $0.isFinite }), value.tempo_bpm.isFinite,
              (30...300).contains(value.tempo_bpm), value.preset <= 2 else { throw AudioSessionError.invalidPlan }
        let coalesces = pendingControls.last.map { $0.preset == value.preset && $0.muted == value.muted } ?? false
        guard coalesces || pendingControls.count < TransportConfiguration.pendingControls else {
            throw AudioSessionError.capacity
        }
    }

    private func enqueueControls(_ value: CodaControls) {
        // Coalesce only continuous changes with identical preset/mute. Preserve
        // mute/unmute and preset edges in FIFO order through backpressure.
        if let last = pendingControls.last, last.preset == value.preset, last.muted == value.muted {
            pendingControls[pendingControls.count - 1] = value
        } else {
            pendingControls.append(value)
        }
        controls = value
    }

    private func applyMixerControls(_ next: CodaMixerControls) {
        mixerControls = next
        syncLegacyControlsFromMixer()
        if let last = pendingMixerControls.last,
           last.layers.0.preset == next.layers.0.preset && last.layers.0.muted == next.layers.0.muted &&
           last.layers.1.preset == next.layers.1.preset && last.layers.1.muted == next.layers.1.muted &&
           last.layers.2.preset == next.layers.2.preset && last.layers.2.muted == next.layers.2.muted {
            pendingMixerControls[pendingMixerControls.count - 1] = next
        } else if pendingMixerControls.count < TransportConfiguration.pendingControls {
            pendingMixerControls.append(next)
        } else {
            pendingMixerControls[pendingMixerControls.count - 1] = next
        }
        if available { pump() }
    }

    private func syncLegacyControlsFromMixer() {
        let l0 = mixerControls.layers.0
        controls.wobble = l0.wobble
        controls.warmth = l0.warmth
        controls.cutoff = l0.cutoff
        controls.resonance = l0.resonance
        controls.shape = l0.shape
        controls.detune = l0.detune
        controls.glide = l0.glide
        controls.chord_level = l0.level
        controls.preset = l0.preset
        controls.muted = l0.muted
        controls.delay_amount = mixerControls.delay_amount
        controls.reverb_amount = mixerControls.reverb_amount
        controls.tempo_bpm = mixerControls.tempo_bpm
    }

    private func syncMixerFromLegacyControls(_ value: CodaControls) {
        mixerControls.layers.0.wobble = value.wobble
        mixerControls.layers.0.warmth = value.warmth
        mixerControls.layers.0.cutoff = value.cutoff
        mixerControls.layers.0.resonance = value.resonance
        mixerControls.layers.0.shape = value.shape
        mixerControls.layers.0.detune = value.detune
        mixerControls.layers.0.glide = value.glide
        mixerControls.layers.0.level = value.chord_level
        mixerControls.layers.0.preset = value.preset
        mixerControls.layers.0.muted = value.muted
        mixerControls.delay_amount = value.delay_amount
        mixerControls.reverb_amount = value.reverb_amount
        mixerControls.tempo_bpm = value.tempo_bpm
    }

    private var currentMutedLayers: Set<MusicLayer> {
        var set = Set<MusicLayer>()
        if mixerControls.layers.0.muted != 0 { set.insert(.chords) }
        if mixerControls.layers.1.muted != 0 { set.insert(.bass) }
        if mixerControls.layers.2.muted != 0 { set.insert(.melody) }
        return set
    }

    private func reconciledBass(from previous: Progression, to updated: Progression) -> BassTrack {
        if bassTrack.notes.isEmpty && previous.regions.isEmpty && !updated.regions.isEmpty {
            let seeded = BassFollower.seedFromProgression(updated, vocabulary: vocabulary)
            return (try? BassTrack(notes: seeded)) ?? bassTrack
        }
        guard !bassTrack.notes.isEmpty else { return bassTrack }
        let reconciled = BassFollower.reconcile(
            bassNotes: bassTrack.notes,
            previousRegions: previous.regions,
            newRegions: updated.regions,
            vocabulary: vocabulary
        )
        return (try? BassTrack(notes: reconciled)) ?? bassTrack
    }

    private func currentSnapshot() -> SessionStateSnapshot {
        SessionStateSnapshot(
            progression: editor.progression,
            patterns: patterns,
            bassTrack: bassTrack,
            melodyTrack: melodyTrack,
            key: key,
            loop: loop
        )
    }

    private static func presetID(for index: UInt8) -> String {
        switch index {
        case 1: return "currents"
        case 2: return "wobble"
        default: return "pluck"
        }
    }

    private static func presetIndex(for id: String) -> UInt8 {
        switch id {
        case "currents", "subBass": return 1
        case "wobble", "pluckedKeys": return 2
        default: return 0
        }
    }

    private static func synthState(from mixer: CodaMixerControls) -> MixerAndSynthState {
        func mapLayer(_ lc: CodaLayerControls) -> LayerSynthState {
            LayerSynthState(
                presetID: presetID(for: lc.preset),
                volume: Double(lc.level),
                filterCutoff: Double(lc.cutoff),
                resonance: Double(lc.resonance),
                attack: Double(lc.shape),
                release: Double(lc.detune),
                wobble: Double(lc.wobble),
                warmth: Double(lc.warmth),
                glide: Double(lc.glide),
                muted: lc.muted != 0
            )
        }
        return MixerAndSynthState(
            chords: mapLayer(mixer.layers.0),
            bass: mapLayer(mixer.layers.1),
            melody: mapLayer(mixer.layers.2),
            sharedFX: SharedFXState(
                chorusMix: Double(mixer.chorus_amount),
                delayMix: Double(mixer.delay_amount),
                reverbMix: Double(mixer.reverb_amount)
            )
        )
    }

    private static func mixerControls(from state: MixerAndSynthState, tempo: Double) -> CodaMixerControls {
        var mixer = coda_dsp_default_mixer_controls()
        func mapLayer(_ ls: LayerSynthState, into lc: inout CodaLayerControls) {
            lc.preset = presetIndex(for: ls.presetID)
            lc.level = Float(min(1, max(0, ls.volume)))
            lc.cutoff = Float(min(1, max(0, ls.filterCutoff)))
            lc.resonance = Float(min(1, max(0, ls.resonance)))
            lc.shape = Float(min(1, max(0, ls.attack)))
            lc.detune = Float(min(1, max(0, ls.release)))
            lc.wobble = Float(min(1, max(0, ls.wobble)))
            lc.warmth = Float(min(1, max(0, ls.warmth)))
            lc.glide = Float(min(1, max(0, ls.glide)))
            lc.muted = ls.muted ? 1 : 0
        }
        mapLayer(state.chords, into: &mixer.layers.0)
        mapLayer(state.bass, into: &mixer.layers.1)
        mapLayer(state.melody, into: &mixer.layers.2)
        mixer.chorus_amount = Float(min(1, max(0, state.sharedFX.chorusMix)))
        mixer.delay_amount = Float(min(1, max(0, state.sharedFX.delayMix)))
        mixer.reverb_amount = Float(min(1, max(0, state.sharedFX.reverbMix)))
        mixer.tempo_bpm = Float(min(300, max(30, tempo)))
        return mixer
    }

    public func status() -> CodaTransportStatus {
        let status = audio.transportStatus()
        if status.failures > 0 { error = "Native audio scheduling failure" }
        renderedPlaying = status.playing != 0
        // An observation from before the latest explicit Play cannot cancel it.
        if available && status.playback_revision == playbackRevision {
            playing = renderedPlaying
        }
        return status
    }

    /// Bounded integration-test entry point: invokes the actual engine, not a
    /// replacement renderer. Internal so the next UI cannot use it as export.
    func renderOffline(frames: UInt32, pumping: Bool = true) throws -> Double {
        if pumping { pump() }
        var totalEnergy = 0.0
        var remaining = frames
        let chunkLimit: UInt32 = pumping ? 48_000 : frames
        while remaining > 0 {
            let chunk = min(remaining, max(1, chunkLimit))
            var chunkEnergy = 0.0
            try audio.renderOffline(frames: chunk, energy: &chunkEnergy)
            totalEnergy += chunkEnergy
            remaining -= chunk
            if pumping { pump() }
        }
        return totalEnergy
    }

    // Internal observation of the real serialized producer for deterministic
    // offline interleavings. No status injection or alternate render path.
    var planDiagnostics: (active: UInt64, pending: UInt64, desired: Bool,
                          nextCycle: Int64?, playback: UInt64, position: UInt64,
                          native: CodaPerformanceStatus) {
        (activeGeneration, publishedGeneration, desiredPlan != nil,
         activeSource?.nextCycle, playbackRevision, positionRevision, audio.performanceStatus())
    }

    private func playbackSpan() throws -> LoopSpan {
        if looping { return loop }
        return try LoopSpan(bars: editor.progression.totalSteps / MusicDefaults.stepsPerBar)
    }
    private func schedule(seek: Int? = nil) throws {
        commitPlan(try preparePlan(seek: seek))
    }
    private func preparePlan(progression: Progression? = nil, arrangement: PatternArrangement? = nil,
                             bass: BassTrack? = nil, melody: MelodyTrack? = nil,
                             tempo: Double? = nil, loop: LoopSpan? = nil, looping: Bool? = nil,
                             playing: Bool? = nil, seek: Int? = nil) throws -> PreparedPlan {
        let progression = progression ?? editor.progression
        for region in progression.regions {
            guard region.pitches.count <= 12 else { throw AudioSessionError.capacity }
        }
        let bass = bass ?? bassTrack
        let melody = melody ?? melodyTrack
        let tempo = tempo ?? self.tempo
        let looping = looping ?? self.looping
        let span: LoopSpan
        if looping { span = loop ?? self.loop }
        else { span = try LoopSpan(bars: progression.totalSteps / MusicDefaults.stepsPerBar) }
        let previousSpan = try playbackSpan()
        let status = audio.transportStatus()
        let nativeStep = Int(exactly: status.step) ?? requestedStep
        let absolutePosition = previousSpan.start + (available ? nativeStep : requestedStep)
        let remapped = min(span.length - 1, max(0, absolutePosition - span.start))
        // Stage 1 loop-disable rebase: when looping transitions true -> false even
        // without a span change, rebase so cycle_index < length / windowSteps holds.
        let disablingLoop = self.looping && !looping
        let explicitSeek = seek ?? ((span != previousSpan || disablingLoop) ? remapped : nil)
        guard playing == nil || playbackRevision < (UInt64.max >> 1),
              explicitSeek == nil || positionRevision < UInt64.max else { throw AudioSessionError.capacity }
        let nextPlayback = playbackRevision + (playing == nil ? 0 : 1)
        let nextPosition = positionRevision + (explicitSeek == nil ? 0 : 1)
        let playingValue = playing ?? playbackIntent
        let step = min(span.length - 1, max(0, explicitSeek ?? requestedStep))
        let rate = audio.sampleRate > 0 ? audio.sampleRate : 48_000
        let arrangement = arrangement ?? patterns
        let unconsumedPosition = nextPosition > audio.performanceStatus().consumed_position_revision
        let unconsumedPlayback = nextPlayback > status.playback_revision
        let restarting = (playing == true || (unconsumedPlayback && playingValue)) && status.completed != 0
        let observed = unconsumedPosition ? UInt64(step / PerformanceCycleSource.windowSteps) : (restarting ? 0 : status.cycle)
        guard let cycle = Int64(exactly: observed), cycle < Int64.max else { throw AudioSessionError.capacity }
        let source = try PerformanceCycleSource(
            progression: progression,
            arrangement: arrangement,
            bassTrack: bass,
            melodyTrack: melody,
            extraLayers: extraLayers,
            tempo: tempo,
            sampleRate: rate,
            span: span,
            initialCycle: cycle
        )
        let payload = try source.compile(cycle: cycle)
        let storage = NativePerformancePlan()
        storage.pointer.pointee.initial_cycle = payload.pointer.pointee
        storage.pointer.pointee.samples_per_step = rate * 60 / tempo / Double(MusicDefaults.stepsPerBeat)
        storage.pointer.pointee.length = UInt64(span.length)
        storage.pointer.pointee.window_steps = UInt64(PerformanceCycleSource.windowSteps)
        storage.pointer.pointee.playback_revision = nextPlayback
        storage.pointer.pointee.position_revision = nextPosition
        storage.pointer.pointee.seek_step = UInt64(step)
        storage.pointer.pointee.playing = playingValue ? 1 : 0
        storage.pointer.pointee.looping = looping ? 1 : 0
        return PreparedPlan(native: nil, performance: storage, source: source,
            playbackRevision: nextPlayback, positionRevision: nextPosition, playing: playingValue, step: step)
    }
    private func commitPlan(_ plan: PreparedPlan) {
        // Native plan replacement already retires its old audition. Do not let
        // an obsolete cancel command override music owned by this new plan.
        if plan.native != nil || plan.performance != nil {
            auditionPreviewOwner = nil
            pendingPreviewStop = nil
        }
        if plan.playbackRevision != playbackRevision { playing = plan.playing }
        playbackIntent = plan.playing
        playbackRevision = plan.playbackRevision
        positionRevision = plan.positionRevision
        requestedStep = plan.step
        desiredPlan = plan
        if available { pump() }
    }

    private func observeAudioLifecycle() {
        let epoch = lifecycleEpoch
        // Register only after category/activation/engine startup completes. Engine
        // notifications are scoped to this adapter, never another engine.
        let sources: [(Notification.Name, AnyObject?)] = [
            (AVAudioSession.interruptionNotification, AVAudioSession.sharedInstance()),
            (AVAudioSession.routeChangeNotification, AVAudioSession.sharedInstance()),
            (.AVAudioEngineConfigurationChange, audio.configurationOwner)
        ]
        for (name, owner) in sources {
            guard let owner else { continue }
            audioObservers.values.append(NotificationCenter.default.addObserver(forName: name, object: owner, queue: nil) { [weak self] notification in
                // Extract only Sendable values before leaving Apple's callback.
                let reason = (notification.userInfo?[name == AVAudioSession.interruptionNotification
                    ? AVAudioSessionInterruptionTypeKey : AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                Task { @MainActor [weak self] in
                    self?.handleAudioNotification(name: name, reason: reason, epoch: epoch)
                }
            })
        }
    }
    func handleAudioNotification(name: Notification.Name, reason: UInt?, epoch: UUID) {
        guard available, epoch == lifecycleEpoch else { return }
        if name == AVAudioSession.interruptionNotification {
            guard reason == AVAudioSession.InterruptionType.began.rawValue else { return }
        } else if name == AVAudioSession.routeChangeNotification {
            guard let reason, let change = AVAudioSession.RouteChangeReason(rawValue: reason) else { return }
            switch change {
            case .newDeviceAvailable, .oldDeviceUnavailable, .override, .wakeFromSleep,
                 .noSuitableRouteForCategory, .routeConfigurationChange: break
            default: return // categoryChange/unknown do not invalidate output by themselves
            }
        } else if name == .AVAudioEngineConfigurationChange {
            guard audio.configurationInvalidated else { return }
        } else { return }
        suspend() // MainActor; never teardown in Apple's internal notification handler.
    }
    // MainActor is the single serialized producer. A queue success never retires
    // ACTIVE; only an explicit matching application acknowledges replacement.
    private func pumpPlans() throws {
        let status = audio.performanceStatus()
        // Native drains legacy snapshots cumulatively. Only an explicit matching
        // generation ACK retires the facade's bounded publication window.
        if let acknowledged = legacyUnconsumed.firstIndex(of: status.applied_generation) {
            legacyUnconsumed.removeFirst(acknowledged + 1)
        }
        if let rejected = legacyUnconsumed.firstIndex(of: status.rejected_generation) {
            legacyUnconsumed.remove(at: rejected)
        }
        if let pending = publishedPlan {
            if status.applied_generation == publishedGeneration {
                activeSource = pending.source; activeGeneration = publishedGeneration
                publishedPlan = nil; publishedGeneration = 0
            } else if status.rejected_generation == publishedGeneration {
                if desiredPlan == nil { desiredPlan = pending }
                publishedPlan = nil; publishedGeneration = 0
                if let desired = desiredPlan, let source = desired.source, let storage = desired.performance {
                    // required_cycle is only a hint; native remains admission authority.
                    let unconsumedPosition = desired.positionRevision > audio.performanceStatus().consumed_position_revision
                    let observed: UInt64 = unconsumedPosition ? UInt64(desired.step / PerformanceCycleSource.windowSteps) : max(audio.transportStatus().cycle, status.required_cycle)
                    guard let cycle = Int64(exactly: observed), cycle < Int64.max else { throw AudioSessionError.capacity }
                    let retrySource = try PerformanceCycleSource(
                        progression: source.progression,
                        arrangement: source.arrangement,
                        bassTrack: source.bassTrack,
                        melodyTrack: source.melodyTrack,
                        mutedLayers: source.mutedLayers,
                        tempo: source.tempo,
                        sampleRate: source.sampleRate,
                        span: source.span,
                        initialCycle: cycle
                    )
                    let replacement = try retrySource.compile(cycle: cycle)
                    storage.pointer.pointee.initial_cycle = replacement.pointer.pointee
                    desiredPlan = PreparedPlan(native: nil, performance: storage, source: retrySource,
                        playbackRevision: desired.playbackRevision, positionRevision: desired.positionRevision,
                        playing: desired.playing, step: desired.step)
                }
            }
        }
        // Fixed budget, active first, own cursor/POD per generation. Mixed atomic
        // observations never authorize dropping a cycle or retiring a source.
        for _ in 0..<2 {
            if let source = activeSource {
                let result = try source.refill(audio: audio, generation: activeGeneration,
                    currentCycle: audio.transportStatus().cycle)
                if result < 0 {
                    let fresh = audio.performanceStatus()
                    guard publishedPlan != nil, fresh.applied_generation == publishedGeneration else {
                        throw AudioSessionError.invalidPlan
                    }
                    // Matching replacement ACK proves this source retired. The
                    // next pump promotes it before attempting any more refills.
                    break
                }
            }
        }
        // Legacy snapshots have no refill source and native drains them to the
        // latest cumulative intent. Preserve that pre-pattern behavior. A live
        // performance source still requires an explicit retirement ACK.
        let replacesLegacy = activeSource == nil && publishedPlan?.native != nil && desiredPlan?.native != nil
        if publishedPlan == nil || replacesLegacy, let desired = desiredPlan,
           desired.native == nil || legacyUnconsumed.count < 2 {
            var generation: UInt64 = 0
            let result: Int32
            if let performance = desired.performance {
                result = audio.publish(performancePlan: performance.pointer, generation: &generation)
            } else if let native = desired.native {
                result = audio.publish(plan: native.pointer, generation: &generation)
            } else { throw AudioSessionError.invalidPlan }
            if result < 0 { throw AudioSessionError.invalidPlan }
            if result == 1 {
                if desired.native != nil { legacyUnconsumed.append(generation) }
                publishedPlan = desired; publishedGeneration = generation; desiredPlan = nil
            }
        }
        if let pending = publishedPlan, let source = pending.source {
            let result = try source.refill(audio: audio, generation: publishedGeneration,
                currentCycle: audio.transportStatus().cycle)
            // -1 is failure until an explicit matching ACK proves retirement.
            if result < 0 {
                let fresh = audio.performanceStatus()
                guard fresh.rejected_generation == publishedGeneration else {
                    throw AudioSessionError.invalidPlan
                }
            }
        }
    }

    private func pump() {
        guard available else { return }
        if let owner = pendingPreviewStop {
            if owner != auditionPreviewOwner {
                pendingPreviewStop = nil
            } else {
                // Empty audition is the existing native release/restore command.
                let result = audio.audition(pitches: nil, count: 0, frames: 0)
                if result != 0 {
                    pendingPreviewStop = nil
                    auditionPreviewOwner = nil
                    if result < 0 { error = "Native preview cancellation rejected" }
                }
            }
        }
        do { try pumpPlans() }
        catch { self.error = String(describing: error) }
        while !pendingControls.isEmpty {
            var next = pendingControls[0]
            let result = audio.publish(controls: &next)
            if result == 0 { break }
            pendingControls.removeFirst()
            if result < 0 { error = "Native controls rejected" }
        }
        while !pendingMixerControls.isEmpty {
            let next = pendingMixerControls[0]
            let result = audio.publish(mixerControls: next)
            if result == 0 { break }
            pendingMixerControls.removeFirst()
            if result < 0 { error = "Native mixer controls rejected" }
        }
        if (desiredPlan != nil || publishedPlan != nil || activeSource != nil ||
            !pendingControls.isEmpty || !pendingMixerControls.isEmpty || pendingPreviewStop != nil), retry == nil {
            let epoch = lifecycleEpoch
            retry = Task { [weak self] in
                try? await Task.sleep(nanoseconds: TransportConfiguration.retryNanoseconds)
                guard !Task.isCancelled, let self, self.lifecycleEpoch == epoch else { return }
                self.retry = nil; self.pump()
            }
        }
    }
}
