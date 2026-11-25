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

private struct PreparedPlan {
    let native: NativePlan?
    let playbackRevision: UInt64
    let positionRevision: UInt64
    let playing: Bool
    let step: Int
}

@MainActor @Observable
public final class MusicSession {
    public let vocabulary: ChordVocabulary
    public let solver = VoiceLeadingSolver()
    public let suggestions = RuleBasedChordSuggestions()
    public private(set) var editor: ProgressionEditor
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
    @ObservationIgnored private var pendingPlan: NativePlan?
    @ObservationIgnored private var pendingControls: [CodaControls] = []
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
        editor = ProgressionEditor(try Progression(vocabulary: vocabulary))
        loop = try LoopSpan()
        coda_dsp_default_controls(0, &controls)
    }

    /// Lazy output-only startup. Ordinary empty launch does not start hardware.
    public func activate() throws {
        guard !available else { return }
        do {
            try audio.open(offline: offline)
            let plan = try preparePlan()
            try audio.start()
            available = true
            if pendingControls.isEmpty { pendingControls.append(controls) }
            commitPlan(plan)
            observeAudioLifecycle()
            pump()
            error = nil
        } catch {
            let savedPlayback = playbackRevision, savedPosition = positionRevision
            let savedPlaying = playing, savedIntent = playbackIntent, savedStep = requestedStep
            // Failed startup must retain unpublished preset/mute edges for retry.
            let savedControls = pendingControls
            suspend()
            pendingControls = savedControls
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
        pendingPlan = nil
        pendingControls.removeAll()
        audio.close()
        available = false; playing = false; renderedPlaying = false
        // Reopen creates a fresh native epoch; retire all old commands.
        playbackIntent = false; playbackRevision = 0; positionRevision = 0; requestedStep = 0
    }

    public func play() throws { try activate(); try changePlayback(playing: true) }
    public func pause() throws { try changePlayback(playing: false) }
    public func stop() throws { try changePlayback(playing: false, seek: 0) }
    public func restart() throws { try activate(); try changePlayback(playing: true, seek: 0) }
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
        let plan = try preparePlan(progression: candidate.progression)
        editor = candidate
        commitPlan(plan)
    }
    public func undo() throws {
        var candidate = editor
        if candidate.undo() {
            let plan = try preparePlan(progression: candidate.progression)
            editor = candidate; commitPlan(plan)
        }
    }
    public func redo() throws {
        var candidate = editor
        if candidate.redo() {
            let plan = try preparePlan(progression: candidate.progression)
            editor = candidate; commitPlan(plan)
        }
    }
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
    func renderOffline(frames: UInt32) throws -> Double {
        var energy = 0.0
        try audio.renderOffline(frames: frames, energy: &energy)
        return energy
    }

    private func playbackSpan() throws -> LoopSpan {
        if looping { return loop }
        return try LoopSpan(bars: editor.progression.totalSteps / MusicDefaults.stepsPerBar)
    }
    private func schedule(seek: Int? = nil) throws {
        commitPlan(try preparePlan(seek: seek))
    }
    private func preparePlan(progression: Progression? = nil, tempo: Double? = nil,
                             loop: LoopSpan? = nil, looping: Bool? = nil,
                             playing: Bool? = nil, seek: Int? = nil) throws -> PreparedPlan {
        let progression = progression ?? editor.progression
        let tempo = tempo ?? self.tempo
        let looping = looping ?? self.looping
        // Exhaustion rejects the whole request before mutation/publication. A
        // deliberate suspend/reopen starts a fresh epoch; never wrap counters.
        guard playing == nil || playbackRevision < (UInt64.max >> 1),
              seek == nil || positionRevision < UInt64.max else { throw AudioSessionError.capacity }
        let nextPlayback = playbackRevision + (playing == nil ? 0 : 1)
        let nextPosition = positionRevision + (seek == nil ? 0 : 1)
        let playing = playing ?? playbackIntent
        let step = seek ?? requestedStep
        let span: LoopSpan
        if looping { span = loop ?? self.loop }
        else { span = try LoopSpan(bars: progression.totalSteps / MusicDefaults.stepsPerBar) }
        // The music model allows more than twelve pitches; reject such edits
        // before history/intent changes, even while hardware is inactive.
        guard progression.regions.count <= 128,
              progression.regions.allSatisfy({ $0.pitches.count <= 12 }) else { throw AudioSessionError.capacity }
        guard audio.sampleRate > 0 else {
            return PreparedPlan(native: nil, playbackRevision: nextPlayback,
                positionRevision: nextPosition, playing: playing, step: step)
        }
        let compiled = try NoteEventCompiler.compile(progression,
            tempo: tempo, sampleRate: audio.sampleRate, loop: span)
        guard compiled.events.count <= Int(CODA_PLAN_EVENTS) else { throw AudioSessionError.capacity }
        let storage = NativePlan()
        let plan = storage.pointer
        plan.pointee.samples_per_step = audio.sampleRate * 60 / tempo / Double(MusicDefaults.stepsPerBeat)
        plan.pointee.length = UInt16(span.length)
        plan.pointee.playback_revision = nextPlayback
        plan.pointee.position_revision = nextPosition
        plan.pointee.seek_step = UInt16(step)
        plan.pointee.count = UInt32(compiled.events.count)
        plan.pointee.playing = playing ? 1 : 0
        plan.pointee.looping = looping ? 1 : 0
        let valid = withUnsafeMutableBytes(of: &plan.pointee.events) { raw -> Bool in
            let events = raw.bindMemory(to: CodaGridEvent.self)
            for (i, e) in compiled.events.enumerated() {
                guard e.voiceIndex < 12, e.regionIndex < 128 else { return false }
                events[i] = CodaGridEvent(step: UInt16(e.stepOffset), region: UInt16(e.regionIndex),
                    kind: UInt8(e.kind.rawValue), pitch: e.pitch, rank: UInt8(e.voiceIndex), reserved: 0)
            }
            return true
        }
        guard valid else { throw AudioSessionError.capacity }
        return PreparedPlan(native: storage, playbackRevision: nextPlayback,
            positionRevision: nextPosition, playing: playing, step: step)
    }
    private func commitPlan(_ plan: PreparedPlan) {
        // Native plan replacement already retires its old audition. Do not let
        // an obsolete cancel command override music owned by this new plan.
        if plan.native != nil {
            auditionPreviewOwner = nil
            pendingPreviewStop = nil
        }
        if plan.playbackRevision != playbackRevision { playing = plan.playing }
        playbackIntent = plan.playing
        playbackRevision = plan.playbackRevision
        positionRevision = plan.positionRevision
        requestedStep = plan.step
        if let native = plan.native { pendingPlan = native }
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
        if let plan = pendingPlan {
            let result = audio.publish(plan: plan.pointer)
            if result != 0 {
                pendingPlan = nil
                if result < 0 { error = "Native event plan rejected" }
            }
        }
        while !pendingControls.isEmpty {
            var next = pendingControls[0]
            let result = audio.publish(controls: &next)
            if result == 0 { break }
            pendingControls.removeFirst()
            if result < 0 { error = "Native controls rejected" }
        }
        if (pendingPlan != nil || !pendingControls.isEmpty || pendingPreviewStop != nil), retry == nil {
            retry = Task { [weak self] in
                try? await Task.sleep(nanoseconds: TransportConfiguration.retryNanoseconds)
                guard !Task.isCancelled, let self else { return }
                self.retry = nil; self.pump()
            }
        }
    }
}
