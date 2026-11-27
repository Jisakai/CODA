import Foundation
import Observation
import SwiftUI
import CodaMusic
import CodaSession
import CodaNative
import CodaInteraction

enum EditorPopup: String, Identifiable, Hashable {
    case appSettings
    case projectSettings
    case keyScale
    case tempo
    var id: String { rawValue }
}

enum EditorKnob: String, CaseIterable, Identifiable, Hashable {
    case wobble, warmth, cutoff, resonance, shape, detune, glide
    case delay, reverb, chordLevel

    var id: String { rawValue }
    var title: String {
        switch self {
        case .wobble: "Wobble"
        case .warmth: "Warmth"
        case .cutoff: "Cutoff"
        case .resonance: "Resonance"
        case .shape: "Shape"
        case .detune: "Detune"
        case .glide: "Glide"
        case .delay: "Delay"
        case .reverb: "Reverb"
        case .chordLevel: "Chords"
        }
    }
}

private enum PencilTarget {
    case region(String, resizeEdge: Bool)
    case emptyBar(Int)
    case roll
    case knob(EditorKnob)
    case holdCommand(Int)
    case radial(RadialRing, slot: Int)
    case none
}

enum RadialMode: Equatable { case primary, all, roots }

struct RadialMenuState {
    var mode: RadialMode
    var context: RadialContext
    var regionID: String?
    var emptyStart: Int?
    var anchor: CGPoint
    var placement: RadialPlacement
    var center: CGPoint { placement.origin }
    var selectedRing: RadialRing?
    var selectedSlot: Int?
    var draft: RadialSwapDraft?
    var swapping = false
    var hasNavigated = false
    var pages: [RadialRing: Int] = [:]
}

struct ResizeDraft {
    let region: ChordRegion
    var end: Int
}

struct HoldMenuState {
    let regionID: String
    let origin: CGPoint
    var selectedIndex: Int?
}

struct KnobResetState {
    let knob: EditorKnob
    let center: CGPoint
}

@MainActor @Observable
final class CodaEditorStore {
    let session: MusicSession?
    let startupError: String?

    var popup: EditorPopup? {
        willSet {
            // Every settings control presents through this MainActor boundary.
            // Retire in-flight Pencil work before the modal becomes visible.
            if newValue != nil { pencilTouchCancelled() }
        }
        didSet { recordUIEvent("popup.state \(oldValue?.rawValue ?? "nil")->\(popup?.rawValue ?? "nil")") }
    }
    var detailsVisible = false
    var drawerOpen = false { willSet { if newValue != drawerOpen { pencilTouchCancelled() } } }
    var fxExpanded = false
    var chromeHidden = false { willSet { if newValue != chromeHidden { pencilTouchCancelled() } } }
    var showTempoEditor = false
    var tempoDraft = "124"
    var key = MusicDefaults.key
    var rootSize = CGSize(width: 1366, height: 1024)
    var viewport = EditorViewport(topMIDI: CodaDesignTokens.Geometry.pianoRollTopMIDI) {
        willSet { if newValue != viewport { cancelPatternInput() } }
    }
    private(set) var patternEditing = false
    private(set) var patternPreview: PatternGestureValue?
    private(set) var patternPencilPosition: CGPoint?
    var patternReadoutLabel: String? {
        guard let preview = patternPreview else { return nil }
        switch preview.content {
        case .arrow(_, let level): return (try? ArrowLevel(level))?.readout
        case .chuck(let size): return "v\(Int((size * 100).rounded()))"
        case .remove: return "Remove"
        }
    }
    @ObservationIgnored private var patternGesture = PatternGestureInterpreter()
    @ObservationIgnored private var patternGestureWasActive = false
    @ObservationIgnored private var discardPencilLift = false
    private var patternSqueezeMenu = false
    var patternControlsFrame: CGRect { CGRect(x: max(patternFrame.minX, rootSize.width - 500), y: rollTop + 8, width: min(492, patternFrame.width), height: 48) }
    var selectedRegionID: String?
    var hoveredRegionID: String?
    var hoveredStep: Int?
    var playheadStep = 0
    var radial: RadialMenuState?
    var holdMenu: HoldMenuState?
    var knobReset: KnobResetState?
    var resizeDraft: ResizeDraft?
    var inlineError: String?
    var radialPreview: String?
    var knobReadout: String?
    var transientPoint: CGPoint?
    var knobResetSelected = false
    var visualDetent = 0
    var visualDetentIntensity: CGFloat = 0.32
    var pencilFeedbackSerial = 0
    var pencilFeedbackIsCompletion = false
    var displayScale = 1.0
    var knobFrames: [EditorKnob: CGRect] = [:]

    @ObservationIgnored private var clipboard: ChordClipboard?
    @ObservationIgnored private var touchStart: CGPoint?
    @ObservationIgnored private var touchLast: CGPoint?
    @ObservationIgnored private var touchMoved = false
    @ObservationIgnored private var holdWork: DispatchWorkItem?
    @ObservationIgnored private var holdTriggered = false
    @ObservationIgnored private var nextRegionNumber = 1
    @ObservationIgnored private var rollAngles: [EditorKnob: Double] = [:]
    @ObservationIgnored private var rollAccumulators: [EditorKnob: BarrelRollAccumulator] = [:]
    @ObservationIgnored private var activeRollKnob: EditorKnob?
    @ObservationIgnored private var lastPencilContactTime = 0.0
    @ObservationIgnored private var lastPencilLocation: CGPoint?
    @ObservationIgnored private var lastParameterValues: [EditorKnob: Double] = [:]
    @ObservationIgnored private var fingerPanConsumed = false
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewOwner: UUID?
    @ObservationIgnored private var previewChord: Chord?
    @ObservationIgnored private var lastPreviewTime = -Double.infinity

    // Opt-in, MainActor-only native diagnostics. Never used by audio rendering.
    let uiDiagnosticsEnabled: Bool
    private(set) var uiDiagnosticReport = ""
    @ObservationIgnored private(set) var uiAnchorFrames: [String: [EditorPopup: CGRect]] = [:]
    @ObservationIgnored private(set) var uiPopupFrames: [EditorPopup: CGRect] = [:]
    @ObservationIgnored private var uiEvents: [String] = []
    @ObservationIgnored var uiEventObserver: ((String) -> Void)?

    init(session: MusicSession?, startupError: String? = nil,
         uiDiagnosticsEnabled: Bool = ProcessInfo.processInfo.arguments.contains("--coda-ui-geometry")) {
        self.session = session
        self.startupError = startupError
        self.uiDiagnosticsEnabled = uiDiagnosticsEnabled
    }

    func recordUIEvent(_ event: String) {
        guard uiDiagnosticsEnabled else { return }
        let entry = "\(ProcessInfo.processInfo.systemUptime) \(event)"
        uiEvents.append(entry)
        if uiEvents.count > 96 { uiEvents.removeFirst(uiEvents.count - 96) }
        uiDiagnosticReport = uiEvents.joined(separator: "\n")
        print("M1 UI \(entry)")
        uiEventObserver?(event)
    }

    func recordSettingsFrames(_ frames: [EditorPopup: CGRect], stage: String) {
        guard uiDiagnosticsEnabled, uiAnchorFrames[stage] != frames else { return }
        uiAnchorFrames[stage] = frames
        let description = frames.keys.sorted { $0.rawValue < $1.rawValue }.map {
            "\($0.rawValue)=\(frames[$0]!)"
        }.joined(separator: "; ")
        recordUIEvent("anchors.\(stage) [\(description)]")
    }

    func recordPopupFrame(_ frame: CGRect, popup: EditorPopup) {
        guard uiDiagnosticsEnabled, uiPopupFrames[popup] != frame else { return }
        uiPopupFrames[popup] = frame
        recordUIEvent("popup.geometry.\(popup.rawValue) \(frame)")
    }

    func presentSettings(_ surface: EditorPopup) {
        recordUIEvent("settings.action.\(surface.rawValue)")
        if surface == .tempo { tempoDraft = String(Int(tempo.rounded())) }
        popup = surface
    }

    var regions: [ChordRegion] { session?.editor.progression.regions ?? [] }
    var canUndo: Bool { session?.canUndo ?? false }
    var canRedo: Bool { session?.canRedo ?? false }
    var tempo: Double { session?.tempo ?? MusicDefaults.tempo }
    var looping: Bool { session?.looping ?? true }
    var loop: LoopSpan { session?.loop ?? (try! LoopSpan()) }
    var controls: CodaControls { session?.controls ?? CodaControls() }
    var audioAvailable: Bool { session?.available ?? false }
    var isPlaying: Bool { session?.playing ?? false }
    var audioError: String? { session?.error }
    var totalSteps: Int { session?.editor.progression.totalSteps ?? MusicDefaults.canvasBars * MusicDefaults.stepsPerBar }
    var regionCount: Int { regions.count }

    var timelineTop: CGFloat { CodaDesignTokens.Geometry.topBarHeight }
    var stripTop: CGFloat { timelineTop + CodaDesignTokens.Geometry.timelineHeight }
    var rollTop: CGFloat { chromeHidden ? 0 : stripTop + CodaDesignTokens.Geometry.chordStripHeight }
    var contentWidth: CGFloat { max(1, rootSize.width - CodaDesignTokens.Geometry.pitchGutterWidth) }
    var drawerWidth: CGFloat {
        min(CodaDesignTokens.Geometry.drawerMaxWidth,
            max(CodaDesignTokens.Geometry.drawerMinWidth, rootSize.width * CodaDesignTokens.Geometry.drawerFraction))
    }
    // The side surface covers the strip and roll, below the shared transport.
    var drawerTop: CGFloat { stripTop }
    var synthTop: CGFloat {
        drawerTop + (rootSize.height - drawerTop) * CodaDesignTokens.EditorSurface.drawerReservedFraction
    }

    func setRootSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if size != rootSize, patternGestureWasActive { pencilTouchCancelled() }
        rootSize = size
        if !hasActivePencilTouch, var state = radial {
            guard let placement = menuPlacement(state.anchor, mode: state.mode) else {
                closeRadial()
                return
            }
            state.placement = placement
            radial = state
        }
    }

    func refreshTransportStatus() {
        guard let session else { return }
        let start = session.looping ? session.loop.start : 0
        if session.available {
            let status = session.status()
            playheadStep = start + Int(status.step)
        } else {
            playheadStep = start + session.requestedStep
        }
    }

    func togglePlayback() {
        guard let session else { setError(startupError ?? "Audio session is unavailable."); return }
        do {
            if session.playing { try session.pause() }
            else { try session.play() }
            inlineError = nil
            refreshTransportStatus()
        } catch { setError(error) }
    }

    func toggleChordMute() {
        recordUIEvent("mute.action before=\(controls.muted)")
        guard let session else { setError(startupError ?? "Audio session is unavailable."); return }
        var updated = session.controls
        updated.muted = updated.muted == 0 ? 1 : 0
        let published = publish(updated)
        recordUIEvent("mute.result published=\(published) after=\(controls.muted) error=\(inlineError ?? "nil")")
    }

    func setTempo(_ value: Double) {
        guard let session else { setError(startupError ?? "Audio session is unavailable."); return }
        do {
            try session.setTempo(min(300, max(30, value)))
            tempoDraft = String(Int(session.tempo.rounded()))
            inlineError = nil
        } catch { setError(error) }
    }

    func stepTempo(by delta: Double) { setTempo(tempo + delta) }

    func commitTempoDraft() {
        guard let value = Double(tempoDraft), value.isFinite else {
            tempoDraft = String(Int(tempo.rounded()))
            return
        }
        setTempo(value)
    }

    func setLoopBars(_ bars: Int, startBar: Int? = nil) {
        let barCount = min(MusicDefaults.canvasBars, max(1, bars))
        guard let session else { return }
        let start = min(MusicDefaults.canvasBars - barCount,
                        max(0, startBar ?? session.loop.start / MusicDefaults.stepsPerBar))
        guard let next = try? LoopSpan(start: start * MusicDefaults.stepsPerBar, bars: barCount) else { return }
        guard next.end <= totalSteps else { return }
        guard next != session.loop else { return }
        let oldPosition = playheadStep
        do {
            try session.setLoop(next, enabled: session.looping)
            let target = session.looping && !(next.start..<next.end).contains(oldPosition) ? next.start : oldPosition
            if (0..<totalSteps).contains(target) { try session.seek(step: target); playheadStep = target }
            inlineError = nil
        }
        catch { setError(error) }
    }

    func toggleLooping() {
        guard let session else { setError(startupError ?? "Audio session is unavailable."); return }
        let target = playheadStep
        do {
            try session.setLoop(session.loop, enabled: !session.looping)
            let position = session.looping && !(session.loop.start..<session.loop.end).contains(target)
                ? session.loop.start : min(totalSteps - 1, max(0, target))
            try session.seek(step: position)
            playheadStep = position
            inlineError = nil
        }
        catch { setError(error) }
    }

    func setKey(tonic: Int, mode: KeyMode) {
        key = MusicalKey(tonic: tonic, mode: mode)
        // Existing chords and stored pitches stay unchanged. The key only changes
        // suggestions, Roman labels and the piano-roll scale shading.
    }

    func openDrawer(_ open: Bool? = nil) {
        withAnimation(.easeOut(duration: CodaDesignTokens.Motion.drawerDuration)) {
            drawerOpen = open ?? !drawerOpen
        }
    }

    func playheadFraction() -> Double {
        let start = session?.looping == true ? (session?.loop.start ?? 0) : 0
        let length = max(1, session?.looping == true ? (session?.loop.length ?? totalSteps) : totalSteps)
        return min(1, max(0, Double(playheadStep - start) / Double(length)))
    }

    func scrub(toX x: CGFloat) {
        guard let step = viewport.step(atX: Double(x - CodaDesignTokens.Geometry.pitchGutterWidth), in: Double(contentWidth)) else { return }
        do { try session?.seek(step: min(totalSteps - 1, max(0, step))); playheadStep = step; inlineError = nil }
        catch { setError(error) }
    }

    func scrubToStep(_ step: Int) {
        guard let session, (0..<totalSteps).contains(step) else { return }
        do { try session.seek(step: step); playheadStep = step; inlineError = nil }
        catch { setError(error) }
    }

    func dragLoopHandle(edge: LoopEdge, toX x: CGFloat) {
        guard session != nil,
              let step = viewport.step(atX: Double(x - CodaDesignTokens.Geometry.pitchGutterWidth), in: Double(contentWidth)) else { return }
        let bar = min(MusicDefaults.canvasBars - 1, max(0, step / MusicDefaults.stepsPerBar))
        let currentStart = loop.start / MusicDefaults.stepsPerBar
        let currentEnd = loop.end / MusicDefaults.stepsPerBar
        switch edge {
        case .start:
            let newStart = min(bar, currentEnd - 1)
            setLoopBars(currentEnd - newStart, startBar: newStart)
        case .end:
            let newEnd = max(currentStart + 1, bar + 1)
            setLoopBars(newEnd - currentStart, startBar: currentStart)
        }
    }

    func panCanvas(by translation: CGPoint) {
        viewport.pan(horizontalBy: Double(translation.x), verticalBy: Double(translation.y),
                     canvasWidth: Double(contentWidth), canvasHeight: Double(max(1, rootSize.height - rollTop)))
    }

    func zoomCanvas(to magnification: CGFloat, atX x: CGFloat) {
        let nextZoom = viewport.horizontalZoom * Double(magnification)
        viewport.zoom(to: nextZoom, anchoredAtX: Double(x - CodaDesignTokens.Geometry.pitchGutterWidth),
                      canvasWidth: Double(contentWidth))
    }

    func setPreset(_ preset: UInt8) {
        guard preset <= 2 else { return }
        guard let session else { setError(startupError ?? "Audio session is unavailable."); return }
        var defaults = CodaControls()
        guard coda_dsp_default_controls(preset, &defaults) != 0 else { return }
        var next = session.controls
        next.preset = preset
        next.wobble = defaults.wobble
        next.warmth = defaults.warmth
        next.cutoff = defaults.cutoff
        next.resonance = defaults.resonance
        next.shape = defaults.shape
        next.detune = defaults.detune
        next.glide = defaults.glide
        // Shared FX, chord level, mute and current tempo are project state.
        guard publish(next) else { return }
    }

    func value(for knob: EditorKnob) -> Double {
        let value = controls
        return switch knob {
        case .wobble: Double(value.wobble)
        case .warmth: Double(value.warmth)
        case .cutoff: Double(value.cutoff)
        case .resonance: Double(value.resonance)
        case .shape: Double(value.shape)
        case .detune: Double(value.detune)
        case .glide: Double(value.glide)
        case .delay: Double(value.delay_amount)
        case .reverb: Double(value.reverb_amount)
        case .chordLevel: Double(value.chord_level)
        }
    }

    func setValue(_ value: Double, for knob: EditorKnob) {
        guard value.isFinite else { return }
        guard let session else { setError(startupError ?? "Audio session is unavailable."); return }
        let normalized = min(1, max(0, value))
        let oldValue = lastParameterValues[knob] ?? self.value(for: knob)
        var next = session.controls
        switch knob {
        case .wobble: next.wobble = Float(normalized)
        case .warmth: next.warmth = Float(normalized)
        case .cutoff: next.cutoff = Float(normalized)
        case .resonance: next.resonance = Float(normalized)
        case .shape: next.shape = Float(normalized)
        case .detune: next.detune = Float(normalized)
        case .glide: next.glide = Float(normalized)
        case .delay: next.delay_amount = Float(normalized)
        case .reverb: next.reverb_amount = Float(normalized)
        case .chordLevel: next.chord_level = Float(normalized)
        }
        guard publish(next) else { return }
        let regularDetents = RollDetentTracker.crossed(from: oldValue, to: normalized,
                                                        spacing: CodaDesignTokens.Input.knobDetentSpacing)
        let defaultValue = presetDefault(for: knob)
        let crossedDefault = (min(oldValue, normalized)...max(oldValue, normalized)).contains(defaultValue)
            && oldValue != normalized && abs(oldValue - defaultValue) > 1e-8
        let atEndpoint = normalized <= 0 || normalized >= 1
        if regularDetents > 0 || crossedDefault || atEndpoint && oldValue != normalized {
            visualDetentIntensity = atEndpoint || crossedDefault ? 0.85 : 0.32
            visualDetent += 1
            let detent = visualDetent
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(160))
                guard self?.visualDetent == detent else { return }
                self?.visualDetent = 0
            }
        }
        lastParameterValues[knob] = normalized
        knobReadout = "\(knob.title) \(Int((normalized * 100).rounded()))%"
        transientPoint = lastPencilLocation
        let readout = knobReadout
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard self?.knobReadout == readout else { return }
            self?.knobReadout = nil
        }
    }

    func presetDefault(for knob: EditorKnob) -> Double {
        var defaults = CodaControls()
        guard coda_dsp_default_controls(controls.preset, &defaults) != 0 else { return 0 }
        return switch knob {
        case .wobble: Double(defaults.wobble)
        case .warmth: Double(defaults.warmth)
        case .cutoff: Double(defaults.cutoff)
        case .resonance: Double(defaults.resonance)
        case .shape: Double(defaults.shape)
        case .detune: Double(defaults.detune)
        case .glide: Double(defaults.glide)
        case .delay: Double(defaults.delay_amount)
        case .reverb: Double(defaults.reverb_amount)
        case .chordLevel: Double(defaults.chord_level)
        }
    }

    func openKnobReset(_ knob: EditorKnob, at point: CGPoint) {
        knobReset = KnobResetState(knob: knob, center: point)
        knobResetSelected = false
    }

    func commitKnobReset() {
        guard let state = knobReset else { return }
        transientPoint = lastPencilLocation ?? state.center
        setValue(presetDefault(for: state.knob), for: state.knob)
        visualDetentIntensity = 0.85
        visualDetent += 1
        pencilFeedbackSerial += 1
        pencilFeedbackIsCompletion = true
        knobReset = nil
        knobResetSelected = false
    }

    func rollKnob(_ knob: EditorKnob, angle: Double, at point: CGPoint) {
        guard angle.isFinite else { return }
        let previous = rollAngles[knob] ?? angle
        rollAngles[knob] = angle
        var delta = (angle - previous) * 180 / .pi
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        var accumulator = rollAccumulators[knob] ?? BarrelRollAccumulator(
            deadZoneDegrees: CodaDesignTokens.Input.barrelDeadZoneDegrees)
        let adjustment = accumulator.consume(degrees: delta)
        rollAccumulators[knob] = accumulator
        guard adjustment != 0 else { return }
        lastPencilLocation = point
        let detentBefore = visualDetent
        setValue(value(for: knob) + adjustment, for: knob)
        if visualDetent != detentBefore {
            pencilFeedbackSerial += 1
            pencilFeedbackIsCompletion = false
        }
    }

    func clearRollTracking() {
        rollAngles.removeAll(keepingCapacity: true)
        rollAccumulators.removeAll(keepingCapacity: true)
        activeRollKnob = nil
    }

    func chordName(_ region: ChordRegion) -> String {
        let symbol = session.flatMap { try? $0.vocabulary.quality(region.chord.qualityID).symbol } ?? region.chord.qualityID
        let root = Self.pitchNames[region.chord.root]
        let bass = region.chord.slashBass.map { "/\(Self.pitchNames[$0])" } ?? ""
        return "\(root)\(symbol)\(bass)"
    }

    func romanNumeral(_ chord: Chord) -> String {
        let degree = (chord.root - key.tonic + 12) % 12
        let scale = key.mode == .major ? [0, 2, 4, 5, 7, 9, 11] : [0, 2, 3, 5, 7, 8, 10]
        guard let index = scale.firstIndex(of: degree) else { return "♭VII" }
        let roots = ["I", "II", "III", "IV", "V", "VI", "VII"]
        let quality = session.flatMap { try? $0.vocabulary.quality(chord.qualityID) }
        let lowercase = quality?.family == .minor || quality?.family == .odd && chord.qualityID.hasPrefix("minor")
        return lowercase ? roots[index].lowercased() : roots[index]
    }

    func harmonicFunction(_ chord: Chord) -> HarmonicFunction {
        session?.suggestions.function(of: chord, in: key) ?? .borrowed
    }

    func functionLabel(_ chord: Chord) -> String {
        switch harmonicFunction(chord) {
        case .tonic: "TON"
        case .subdominant: "SUB"
        case .dominant: "DOM"
        case .borrowed: "BOR"
        }
    }

    func voicingLabel(_ region: ChordRegion) -> String {
        guard let bass = region.pitches.first else { return "Voicing" }
        if bass % 12 == region.chord.root { return "Root" }
        if let low = region.pitches.first, let high = region.pitches.last, high - low >= 12 { return "Spread" }
        return "Inversion"
    }

    func pitchName(_ midi: Int) -> String {
        "\(Self.pitchNames[(midi % 12 + 12) % 12])\(midi / 12 - 1)"
    }

    func alterationText(_ region: ChordRegion) -> String {
        guard let quality = session.flatMap({ try? $0.vocabulary.quality(region.chord.qualityID) }) else { return "" }
        let names: [Int: String] = [13: "♭9", 14: "9", 15: "♯9", 17: "11", 18: "♯11", 20: "♭13", 21: "13", 22: "♯13"]
        return quality.intervals.compactMap { names[$0] }.joined(separator: " · ")
    }

    func scaleContains(_ midi: Int) -> Bool {
        let offsets = key.mode == .major ? [0, 2, 4, 5, 7, 9, 11] : [0, 2, 3, 5, 7, 8, 10]
        let pc = (midi - key.tonic + 12) % 12
        return offsets.contains(pc)
    }

    func suggestions(for regionID: String?) -> [ChordSuggestion] {
        guard let session else { return [] }
        let region = regions.first(where: { $0.id == regionID })
        let previous = region.map { target in
            regions.filter { $0.id != target.id && $0.end <= target.start }.max { $0.end < $1.end }?.chord
        } ?? regions.filter { $0.end <= (hoveredStep ?? 0) }.max { $0.end < $1.end }?.chord
        return (try? session.suggestions.suggestions(existing: region?.chord, previous: previous,
                                                     key: key, vocabulary: session.vocabulary)) ?? []
    }

    func qualities(for family: ChordFamily) -> [ChordQuality] {
        session?.vocabulary.ring(family) ?? []
    }

    func patternControlExcludes(_ point: CGPoint) -> Bool {
        patternEditing && ((drawerOpen && point.x >= rootSize.width - drawerWidth && point.y >= drawerTop)
        || patternControlsFrame.contains(point))
    }

    func patternGeometry(bar: Int, slot: Int, preview: PatternGestureValue? = nil) -> PatternStrokeGeometry? {
        let content: PatternStroke.Content?
        if let preview, preview.bar == bar, preview.slot == slot {
            switch preview.content {
            case .remove: content = nil
            case .arrow(let down, let level): content = .arrow(direction: down ? .down : .up, level: try! ArrowLevel(level))
            case .chuck(let size): content = .chuck(try! ChuckSize(size))
            }
        } else { content = session?.patterns.regions.first { ($0.range.start..<$0.range.end).contains(bar) }?.slots[slot]?.content }
        guard let content else { return nil }
        let x = patternFrame.minX + viewport.x(forStep: Double(bar * 16 + slot * 2 + 1), in: Double(patternFrame.width))
        switch content {
        case .arrow(let direction, let level): return PatternStrokeGeometry(x: x, frame: patternFrame, down: direction == .down, fraction: level.normalizedLength)
        case .chuck(let size): return PatternStrokeGeometry(x: x, frame: patternFrame, down: true, fraction: size.normalizedSize, chuck: true)
        }
    }

    /// Reverse Canvas paint order: the last painted visible stroke owns overlaps.
    func patternHitTarget(at point: CGPoint) -> PatternStrokeTarget? {
        guard patternFrame.contains(point), !patternControlExcludes(point) else { return nil }
        for bar in (0..<(viewport.totalSteps / 16)).reversed() {
            for slot in (0..<8).reversed() {
                if patternGeometry(bar: bar, slot: slot)?.contains(point) == true {
                    return PatternStrokeTarget(bar: bar, slot: slot)
                }
            }
        }
        return nil
    }

    var currentPatternSettings: PatternSettings {
        session?.patterns.regions.first { ($0.range.start..<$0.range.end).contains(loop.start / 16) }?.settings ?? (try! PatternSettings())
    }

    func updatePatternSettings(swing: Double? = nil, loose: Bool? = nil, spread: Double? = nil, preset: Bool = false) {
        guard let session else { return }
        do {
            let range = try PatternDefaults.defaultScope.resolve(loop: session.loop, barCount: session.patterns.barCount)
            let old = session.patterns.regions.first { ($0.range.start..<$0.range.end).contains(range.start) }
            let previous = try old?.settings ?? PatternSettings()
            let settings = try PatternSettings(swing: swing ?? previous.swing,
                humanize: loose.map { $0 ? .loose : .tight } ?? previous.humanize,
                spreadMilliseconds: spread ?? previous.spreadMilliseconds, looseSeed: previous.looseSeed)
            if preset {
                let region = try PatternPreset.popRock.instantiate(id: old?.id ?? UUID().uuidString, range: old?.range ?? range,
                    occupiedStrokeIDs: (0..<6).map { _ in UUID().uuidString }, settings: settings)
                var edits: [PatternEdit] = old.map { [.delete(id: $0.id)] } ?? []
                edits.append(.add(region)); try session.editPatterns(edits)
            } else if let old { try session.editPatterns([.settings(id: old.id, settings)]) }
            else {
                let region = try PatternRegion(id: UUID().uuidString, range: range,
                    slots: [PatternStroke?](repeating: nil, count: 8), settings: settings)
                try session.editPatterns([.add(region)])
            }
        } catch { setError(error) }
    }

    var patternFrame: CGRect {
        CGRect(x: CodaDesignTokens.Geometry.pitchGutterWidth, y: rollTop,
               width: contentWidth, height: max(1, rootSize.height - rollTop))
    }

    /// Opening is read-only: no empty pattern or history item is created.
    func beginPatternEditing() {
        pencilTouchCancelled()
        patternEditing = true
    }

    func endPatternEditing() {
        pencilTouchCancelled()
        patternEditing = false
    }

    private func cancelPatternInput() {
        if patternGestureWasActive { discardPencilLift = true; clearTouch() }
        patternGesture.cancel()
        patternGestureWasActive = false
        patternPreview = nil
        patternPencilPosition = nil
    }

    private func commitPatternGesture(_ value: PatternGestureValue) {
        guard let session else { return }
        do {
            let existing = session.patterns.regions.first { ($0.range.start..<$0.range.end).contains(value.bar) }
            let content: PatternStroke.Content?
            switch value.content {
            case .remove: content = nil
            case .arrow(let down, let level):
                content = .arrow(direction: down ? .down : .up, level: try ArrowLevel(level))
            case .chuck(let size): content = .chuck(try ChuckSize(size))
            }
            if let existing {
                // Replacing equal content retains identity and is a genuine no-op.
                let edit: PatternEdit = if let content {
                    .setStroke(id: existing.id, slot: value.slot, content: content,
                               newStrokeID: existing.slots[value.slot] == nil ? UUID().uuidString : nil)
                } else { .removeStroke(id: existing.id, slot: value.slot) }
                try session.editPatterns([edit])
            } else if let content {
                let range = try PatternDefaults.defaultScope.resolve(loop: session.loop, barCount: session.patterns.barCount)
                guard (range.start..<range.end).contains(value.bar) else { return }
                var slots = [PatternStroke?](repeating: nil, count: PatternDefaults.slotsPerBar)
                slots[value.slot] = try PatternStroke(id: UUID().uuidString, content: content)
                let region = try PatternRegion(id: UUID().uuidString, range: range, slots: slots, settings: PatternSettings())
                try session.editPatterns([.add(region)])
            }
            inlineError = nil
        } catch { setError(error) }
    }

    func pencilTouchBegan(at point: CGPoint) {
        guard popup == nil, !patternControlExcludes(point) else { return }
        discardPencilLift = false
        lastPencilContactTime = ProcessInfo.processInfo.systemUptime
        lastPencilLocation = point
        touchStart = point
        touchLast = point
        touchMoved = false
        holdTriggered = false
        if patternEditing, radial == nil, patternFrame.contains(point) {
            let existing = patternHitTarget(at: point)
            patternGesture.begin(at: point, device: .pencil, frame: patternFrame, viewport: viewport, existing: existing)
            patternGestureWasActive = patternGesture.isActive
            patternPencilPosition = patternGesture.isActive ? point : nil
            return
        }
        guard radial == nil, let hit = pencilTarget(at: point) else { return }
        if case .region(let id, true) = hit,
           let region = regions.first(where: { $0.id == id }) {
            resizeDraft = ResizeDraft(region: region, end: region.end)
        }
        if case .region(let id, false) = hit {
            scheduleHold(for: id, at: point)
        }
    }

    func pencilTouchMoved(to point: CGPoint) {
        guard popup == nil else { return }
        lastPencilContactTime = ProcessInfo.processInfo.systemUptime
        lastPencilLocation = point
        touchLast = point
        if patternGestureWasActive {
            patternGesture.move(to: point); patternPreview = patternGesture.preview
            patternPencilPosition = patternGesture.isActive ? point : nil
            return
        }
        guard let start = touchStart else {
            updateRadialHover(at: point)
            return
        }
        if hypot(point.x - start.x, point.y - start.y) >= CodaDesignTokens.Input.holdMoveTolerance {
            touchMoved = true
            holdWork?.cancel(); holdWork = nil
        }
        if let reset = knobReset {
            let distance = hypot(point.x - reset.center.x, point.y - reset.center.y)
            knobResetSelected = distance >= 16 && distance <= 52
            return
        }
        if holdMenu != nil { hoverHoldCommand(at: point); return }
        if radial != nil { updateRadialHover(at: point); return }
        if var draft = resizeDraft {
            if let step = viewport.step(atX: Double(point.x - CodaDesignTokens.Geometry.pitchGutterWidth), in: Double(contentWidth)) {
                draft.end = min(totalSteps, max(draft.region.start + 1, step + 1))
                resizeDraft = draft
                hoveredRegionID = draft.region.id
            }
        } else {
            hoveredRegionID = region(at: point)?.id
        }
    }

    func pencilTouchEnded(at point: CGPoint) {
        if discardPencilLift { discardPencilLift = false; clearTouch(); return }
        guard popup == nil else { return }
        lastPencilLocation = point
        touchLast = point
        holdWork?.cancel(); holdWork = nil
        if patternGestureWasActive {
            let result = patternGesture.finish(at: point)
            cancelPatternInput(); discardPencilLift = false; clearTouch()
            if let result { commitPatternGesture(result) }
            return
        }
        if knobReset != nil {
            if knobResetSelected { commitKnobReset() }
            else { knobReset = nil; knobResetSelected = false }
            clearTouch()
            return
        }
        if let radial {
            commitRadial(radial, at: point)
            clearTouch()
            return
        }
        if let holdMenu {
            if let index = holdMenuLayout?.row(at: point) { performHoldCommand(index, regionID: holdMenu.regionID) }
            self.holdMenu = nil
            clearTouch()
            return
        }
        if let draft = resizeDraft {
            if validResize(draft) {
                performMusicAction(.resize) {
                    guard let session = self.session else { return }
                    try session.edit([.resize(id: draft.region.id, start: draft.region.start,
                                              length: draft.end - draft.region.start)])
                }
            } else {
                setError("That resize overlaps another chord or leaves the canvas.")
            }
            resizeDraft = nil
            clearTouch()
            return
        }
        if touchStart != nil && !touchMoved && !holdTriggered { performPencilTap(at: point) }
        clearTouch()
    }

    func pencilTouchCancelled() {
        cancelPatternInput()
        cancelRadialPreview()
        holdWork?.cancel(); holdWork = nil
        resizeDraft = nil
        holdMenu = nil
        radial = nil
        patternSqueezeMenu = false
        radialPreview = nil
        knobReset = nil
        knobResetSelected = false
        clearRollTracking()
        clearTouch()
    }

    func pencilHover(at point: CGPoint, rollAngle: Double?) {
        guard popup == nil else { return }
        lastPencilLocation = point
        hoveredRegionID = region(at: point)?.id
        hoveredStep = viewport.step(atX: Double(point.x - CodaDesignTokens.Geometry.pitchGutterWidth), in: Double(contentWidth))
        updateRadialHover(at: point)
        if let reset = knobReset {
            let distance = hypot(point.x - reset.center.x, point.y - reset.center.y)
            knobResetSelected = distance >= 16 && distance <= 52
        }
        if let knob = knob(at: point), let rollAngle {
            if activeRollKnob != knob {
                rollAngles.removeAll(keepingCapacity: true)
                rollAccumulators.removeAll(keepingCapacity: true)
                activeRollKnob = knob
            }
            rollKnob(knob, angle: rollAngle, at: point)
        } else {
            activeRollKnob = nil
            rollAngles.removeAll(keepingCapacity: true)
            rollAccumulators.removeAll(keepingCapacity: true)
        }
    }

    var hasActivePencilTouch: Bool { touchStart != nil }

    func finishSqueeze(at point: CGPoint?) {
        guard popup == nil, !hasActivePencilTouch, radial != nil || knobReset != nil else { return }
        // Edge clamping can put a band beneath the opening tip. The initial
        // release cannot activate it without deliberate Pencil navigation.
        if let state = radial, !state.hasNavigated { return }
        pencilTouchEnded(at: point ?? lastPencilLocation ?? .zero)
    }

    func acceptsPencilLocation(_ point: CGPoint) -> Bool {
        guard popup == nil, !patternControlExcludes(point) else { return false }
        return pencilTarget(at: point) != nil || radial != nil || holdMenu != nil
    }

    func openSqueeze(at location: CGPoint?) {
        guard popup == nil, let point = location ?? lastPencilLocation else { return }
        pencilTouchCancelled()
        cancelRadialPreview()
        lastPencilLocation = point
        if let knob = knob(at: point) {
            openKnobReset(knob, at: point)
            return
        }
        guard !(drawerOpen && point.x >= rootSize.width - drawerWidth && point.y >= drawerTop) else { return }
        guard !patternControlExcludes(point) else { return }
        if patternFrame.contains(point), let placement = menuPlacement(point) {
            discardPencilLift = false
            patternSqueezeMenu = true
            radial = RadialMenuState(mode: .primary, context: .emptyBar, regionID: nil,
                emptyStart: nil, anchor: point, placement: placement,
                selectedRing: nil, selectedSlot: nil, draft: nil)
            return
        }
        guard let stripHit = stripHit(at: point), let placement = menuPlacement(point) else { return }
        switch stripHit {
        case .region(let id, _):
            guard let region = regions.first(where: { $0.id == id }) else { return }
            radial = RadialMenuState(mode: .primary, context: .existingChord, regionID: id,
                                     emptyStart: nil, anchor: point, placement: placement,
                                     selectedRing: nil, selectedSlot: nil,
                                     draft: RadialSwapDraft(root: region.chord.root, qualityID: region.chord.qualityID))
        case .emptyBar(let start):
            radial = RadialMenuState(mode: .primary, context: .emptyBar, regionID: nil,
                                     emptyStart: start, anchor: point, placement: placement,
                                     selectedRing: nil, selectedSlot: nil, draft: nil)
        }
        radialPreview = nil
    }

    func closeRadial() { cancelRadialPreview(); radial = nil; patternSqueezeMenu = false; radialPreview = nil }

    var holdMenuLayout: HoldMenuLayout? {
        holdMenu.map { HoldMenuLayout(origin: $0.origin, viewport: rootSize, minimumY: rollTop,
            width: CodaDesignTokens.Input.holdMenuWidth,
            rowHeight: CodaDesignTokens.Input.holdRowHeight,
            dividerHeight: CodaDesignTokens.Input.holdDividerHeight) }
    }

    func hoverHoldCommand(at point: CGPoint) {
        guard var state = holdMenu else { return }
        state.selectedIndex = holdMenuLayout?.row(at: point)
        holdMenu = state
    }

    func routeFingerGesture(touchCount: Int, tapCount: Int) {
        guard !shouldIgnoreFingerShortcut else { return }
        guard let action = FingerShortcutRouter.action(touchCount: touchCount, tapCount: tapCount) else { return }
        switch action {
        case .undo:
            performFingerHistory { guard let session = self.session else { return }; try session.undo() }
        case .redo:
            performFingerHistory { guard let session = self.session else { return }; try session.redo() }
        case .toggleChrome:
            chromeHidden.toggle()
        }
    }

    var shouldIgnoreFingerShortcut: Bool {
        hasActivePencilTouch || ProcessInfo.processInfo.systemUptime - lastPencilContactTime < 0.18
    }

    func routeFingerPan(from start: CGPoint, to point: CGPoint, translation: CGPoint) {
        guard !fingerPanConsumed else { return }
        let displacement = point.x - start.x
        let horizontal = abs(displacement) > abs(point.y - start.y)
        if drawerOpen, start.x >= rootSize.width - drawerWidth, displacement > 60, horizontal {
            fingerPanConsumed = true
            openDrawer(false)
            return
        }
        if drawerOpen, start.x < rootSize.width - drawerWidth - 24, abs(displacement) > 70, horizontal {
            fingerPanConsumed = true
            openDrawer(false)
            return
        }
        if start.x >= rootSize.width - CodaDesignTokens.Input.navigationEdgeWidth {
            if displacement < -CodaDesignTokens.Input.navigationPanThreshold, horizontal {
                fingerPanConsumed = true
                openDrawer(true)
            }
            return
        }
        if drawerOpen && start.x >= rootSize.width - drawerWidth { return }
        if start.y >= rollTop { panCanvas(by: translation) }
    }

    func routeFingerPinch(scale: CGFloat, at point: CGPoint) {
        guard scale.isFinite, scale > 0 else { return }
        zoomCanvas(to: scale, atX: point.x)
        viewport.setVerticalScale(viewport.semitoneHeight * Double(scale),
                                  anchoredAtY: Double(max(0, point.y - rollTop)),
                                  canvasHeight: Double(max(1, rootSize.height - rollTop)))
    }

    func beginFingerNavigation(at point: CGPoint) -> Bool {
        guard popup == nil, !(patternEditing && patternControlsFrame.contains(point)) else { return false }
        fingerPanConsumed = false
        let atEdge = point.x >= rootSize.width - CodaDesignTokens.Input.navigationEdgeWidth
        return point.y >= (atEdge ? drawerTop : rollTop) && (!(drawerOpen && point.x >= rootSize.width - drawerWidth)
            || point.x >= rootSize.width - CodaDesignTokens.Input.navigationEdgeWidth)
    }

    var radialCenter: CGPoint? { radial?.center ?? knobReset?.center }
    var radialModeName: String? {
        guard let radial else { return knobReset == nil ? nil : "knob-reset" }
        return switch radial.mode {
        case .primary: "primary"
        case .all: "all"
        case .roots: "roots"
        }
    }

    func radialRings() -> [(RadialRing, [String], Double, Double)] {
        guard let radial, let session else { return [] }
        if patternSqueezeMenu { return [(.inner, ["Pattern"], CodaDesignTokens.EditorSurface.radialInnerRadius, CodaDesignTokens.EditorSurface.radialInnerBand)] }
        let quality = radial.regionID.flatMap { id in regions.first(where: { $0.id == id })?.chord }
        switch radial.mode {
        case .primary:
            return [(.inner, radial.context == .existingChord ? ["Swap", "Duplicate", "Copy", "Delete"] : ["Paste", "Rest", "", ""],
                     CodaDesignTokens.EditorSurface.radialInnerRadius, CodaDesignTokens.EditorSurface.radialInnerBand),
                    (.outer, outerLabels(for: radial), CodaDesignTokens.EditorSurface.radialOuterRadius,
                     CodaDesignTokens.EditorSurface.radialOuterBand)]
        case .roots:
            let roots = pageLabels(Self.pitchNames, ring: .roots, state: radial)
            return [(.roots, roots, CodaDesignTokens.EditorSurface.radialOuterRadius,
                     CodaDesignTokens.EditorSurface.radialInnerBand)]
        case .all:
            let families: [(ChordFamily, RadialRing)] = [
                (.major, .major), (.minor, .minor), (.odd, .odd)
            ]
            let currentFamily = quality.flatMap { try? session.vocabulary.quality($0.qualityID).family }
            let ordered = families.sorted { lhs, rhs in
                if lhs.0 == rhs.0 { return false }
                if lhs.0 == currentFamily { return true }
                if rhs.0 == currentFamily { return false }
                return families.firstIndex(where: { $0.0 == lhs.0 })! < families.firstIndex(where: { $0.0 == rhs.0 })!
            }
            return ordered.enumerated().map { index, value in
                (value.1, pageLabels(session.vocabulary.ring(value.0).map { $0.symbol.isEmpty ? "Maj" : $0.symbol },
                                     ring: value.1, state: radial),
                 CodaDesignTokens.EditorSurface.radialFamilyRadius + Double(index) * CodaDesignTokens.EditorSurface.radialFamilySpacing,
                 CodaDesignTokens.EditorSurface.radialFamilyBand)
            }
        }
    }

    private func pageLabels(_ labels: [String], ring: RadialRing, state: RadialMenuState) -> [String] {
        let page = state.pages[ring, default: 0] % RadialPage.count(total: labels.count)
        let visible = RadialPage.indices(total: labels.count, page: page).map { labels[$0] }
        guard labels.count > RadialPage.capacity else { return visible }
        return visible + ["More \(page + 1)/\(RadialPage.count(total: labels.count))"]
    }

    func radialTool(ring: RadialRing, slot: Int) -> ChordTool? {
        guard !patternSqueezeMenu, ring == .inner, let radial else { return nil }
        let tools: [ChordTool] = radial.context == .existingChord
            ? [.swap, .duplicate, .copy, .delete] : [.paste, .rest]
        return tools.indices.contains(slot) ? tools[slot] : nil
    }

    func currentRingIsSelected(_ ring: RadialRing) -> Bool {
        guard let radial else { return false }
        if radial.selectedRing == ring { return true }
        guard radial.mode == .all else { return false }
        guard let id = radial.regionID,
              let region = regions.first(where: { $0.id == id }),
              let family = try? session?.vocabulary.quality(region.chord.qualityID).family else {
            return radial.context == .emptyBar && ring == .major
        }
        return switch family {
        case .major: ring == .major
        case .minor: ring == .minor
        case .odd: ring == .odd
        }
    }

    func radialSlotEnabled(_ ring: RadialRing, slot: Int) -> Bool {
        guard slot >= 0, let state = radial else { return false }
        if patternSqueezeMenu { return ring == .inner && slot == 0 }
        switch state.mode {
        case .primary:
            if ring == .inner {
                return state.context == .existingChord ? slot < 4 : slot == 1 || (slot == 0 && clipboard != nil)
            }
            return ring == .outer && (slot == 3 || suggestions(for: state.regionID).indices.contains(slot))
        case .roots:
            return ring == .roots && slot < (radialRings().first?.1.count ?? 0)
        case .all:
            return radialIntent(for: (ring, slot), state: state) != nil
        }
    }

    func testFixtureSeedIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--coda-ui-fixture-four-bar"),
              let session, session.editor.progression.regions.isEmpty else { return }
        let fixtures: [(Int, Int, String)] = [(0, 0, "minor7"), (8, 16, "major7"), (5, 32, "minor7"), (7, 48, "dominant7")]
        for (root, start, quality) in fixtures {
            guard let chord = try? Chord(root: root, qualityID: quality),
                  let voicings = try? session.solver.solve([chord], vocabulary: session.vocabulary),
                  let pitches = voicings.first,
                  let region = try? ChordRegion(id: "fixture-\(start)", chord: chord, start: start,
                                                length: 16, pitches: pitches) else { continue }
            do { try session.edit([.add(region)]) } catch { setError(error) }
        }
        if ProcessInfo.processInfo.arguments.contains("--coda-ui-fixture-drawer") { drawerOpen = true }
        if ProcessInfo.processInfo.arguments.contains("--coda-ui-fixture-pattern") {
            beginPatternEditing(); updatePatternSettings(preset: true)
        }
        if ProcessInfo.processInfo.arguments.contains("--coda-ui-fixture-radial-edge")
            || ProcessInfo.processInfo.arguments.contains("--coda-ui-fixture-radial-primary") {
            let at = CGPoint(x: 60, y: stripTop + 28)
            selectedRegionID = regions.first?.id
            openSqueeze(at: at)
        }
        if ProcessInfo.processInfo.arguments.contains("--coda-ui-fixture-radial-edge") {
            radial = radial.map { state in
                var moved = state
                moved.anchor = CGPoint(x: 12, y: stripTop + 16)
                moved.mode = .all
                guard let placement = menuPlacement(moved.anchor, mode: .all) else { return state }
                moved.placement = placement
                return moved
            }
        }
        #endif
    }

    private static let pitchNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    private func setError(_ error: Error) { setError(String(describing: error)) }
    private func setError(_ message: String) {
        inlineError = message
    }

    @discardableResult
    private func publish(_ controls: CodaControls) -> Bool {
        guard let session else { setError(startupError ?? "Audio session is unavailable."); return false }
        do { try session.setControls(controls); inlineError = nil; return true }
        catch { setError(error); return false }
    }

    private func performMusicAction(_ action: MusicEditAction, _ work: () throws -> Void) {
        guard EditorInputRouter.accepts(action, from: .pencil) else { return }
        do { try work(); inlineError = nil }
        catch { setError(error) }
    }

    private func performFingerHistory(_ work: () throws -> Void) {
        guard !shouldIgnoreFingerShortcut else { return }
        do { try work(); inlineError = nil }
        catch { setError(error) }
    }

    private func performPencilTap(at point: CGPoint) {
        guard let hit = pencilTarget(at: point) else { return }
        switch hit {
        case .region(let id, _):
            selectedRegionID = id
            performMusicAction(.select) {
                guard let session = self.session else { return }
                try session.audition(regionID: id)
                self.inlineError = nil
            }
        case .emptyBar(let start): addNextSuggestion(at: start)
        case .roll, .knob, .holdCommand, .radial, .none: break
        }
    }

    private func addNextSuggestion(at start: Int) {
        guard EditorInputRouter.accepts(.add, from: .pencil) else { return }
        let options = suggestions(for: nil)
        guard !options.isEmpty else { return }
        let hasPreviousChord = regions.contains(where: { $0.end <= start })
        let suggestion = hasPreviousChord ? options[0] : (options.last ?? options[0])
        addChord(suggestion.chord, at: start, length: MusicDefaults.stepsPerBar)
    }

    private func addChord(_ chord: Chord, at start: Int, length: Int) {
        guard let session else { setError(startupError ?? "Music session is unavailable."); return }
        let previous = regions.filter { $0.end <= start }.max { $0.end < $1.end }
        do {
            let pitches = try session.solver.solve([chord], vocabulary: session.vocabulary,
                                                    preceding: previous?.pitches)[0]
            let region = try ChordRegion(id: UUID().uuidString, chord: chord, start: start,
                                         length: length, pitches: pitches)
            try session.edit([.add(region)])
            selectedRegionID = region.id
            nextRegionNumber += 1
            inlineError = nil
        } catch { setError(error) }
    }

    private func performHoldCommand(_ index: Int, regionID: String) {
        guard let region = regions.first(where: { $0.id == regionID }) else { return }
        switch index {
        case 0:
            guard EditorInputRouter.accepts(.copy, from: .pencil) else { return }
            clipboard = try? session?.editor.copy(id: regionID)
        case 1:
            duplicate(region)
        case 2:
            delete(regionID)
        default: break
        }
    }

    private func duplicate(_ region: ChordRegion) {
        guard EditorInputRouter.accepts(.duplicate, from: .pencil) else { return }
        guard region.end + region.length <= totalSteps else { setError("There is no room to duplicate this chord."); return }
        performMusicAction(.duplicate) {
            guard let session = self.session else { return }
            try session.edit([.duplicate(id: region.id, newID: UUID().uuidString, start: region.end)])
        }
    }

    private func delete(_ regionID: String) {
        guard EditorInputRouter.accepts(.delete, from: .pencil) else { return }
        performMusicAction(.delete) { guard let session = self.session else { return }; try session.edit([.delete(id: regionID)]) }
        if selectedRegionID == regionID { selectedRegionID = nil }
    }

    private func copy(_ regionID: String) {
        guard EditorInputRouter.accepts(.copy, from: .pencil) else { return }
        do { clipboard = try session?.editor.copy(id: regionID); inlineError = nil }
        catch { setError(error) }
    }

    private func paste(at start: Int) {
        guard EditorInputRouter.accepts(.paste, from: .pencil), let clipboard else { return }
        performMusicAction(.paste) {
            guard let session = self.session else { return }
            try session.edit([.paste(clipboard, newID: UUID().uuidString, start: start)])
        }
    }

    private func validResize(_ draft: ResizeDraft) -> Bool {
        guard let session else { return false }
        do {
            let replaced = regions.filter { $0.id != draft.region.id }
            let resized = try ChordRegion(id: draft.region.id, chord: draft.region.chord,
                                          start: draft.region.start, length: draft.end - draft.region.start,
                                          pitches: draft.region.pitches)
            _ = try Progression(totalSteps: totalSteps, regions: replaced + [resized], vocabulary: session.vocabulary)
            return true
        } catch { return false }
    }

    private func scheduleHold(for id: String, at point: CGPoint) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.popup == nil, self.hasActivePencilTouch, !self.touchMoved else { return }
            self.holdTriggered = true
            self.holdMenu = HoldMenuState(regionID: id, origin: point, selectedIndex: nil)
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CodaDesignTokens.Input.holdDuration, execute: work)
    }

    private func clearTouch() {
        touchStart = nil
        touchLast = nil
        touchMoved = false
        holdTriggered = false
    }

    private func pencilTarget(at point: CGPoint) -> PencilTarget? {
        if holdMenu != nil { return .holdCommand(0) }
        if radial != nil { return .radial(.inner, slot: 0) }
        if let knob = knob(at: point) { return .knob(knob) }
        if drawerOpen && point.x >= rootSize.width - drawerWidth && point.y >= drawerTop { return nil }
        if point.y >= stripTop, point.y < rollTop, let hit = stripHit(at: point) {
            switch hit {
            case .region(let id, let edge): return .region(id, resizeEdge: edge)
            case .emptyBar(let start): return .emptyBar(start)
            }
        }
        if point.y >= rollTop { return .roll }
        return nil
    }

    private func targetForRadial(_ point: CGPoint) -> PencilTarget? {
        guard let state = radial, let hit = radialHit(at: point, state: state) else { return nil }
        return .radial(hit.0, slot: hit.1)
    }

    private func stripHit(at point: CGPoint) -> ChordStripHit.Target? {
        guard point.y >= stripTop, point.y < rollTop else { return nil }
        return ChordStripHitTester.hit(x: Double(point.x), y: Double(point.y - stripTop),
            width: Double(rootSize.width), height: Double(CodaDesignTokens.Geometry.chordStripHeight),
            headerWidth: Double(CodaDesignTokens.Geometry.pitchGutterWidth), viewport: viewport,
            regions: regions.map { (id: $0.id, start: $0.start, end: $0.end) })?.target
    }

    private func region(at point: CGPoint) -> ChordRegion? {
        guard let target = stripHit(at: point), case .region(let id, _) = target else { return nil }
        return regions.first(where: { $0.id == id })
    }

    func knob(at point: CGPoint) -> EditorKnob? {
        guard drawerOpen, !chromeHidden, point.x >= rootSize.width - drawerWidth,
              point.y >= synthTop, point.y < rootSize.height else { return nil }
        return EditorKnob.allCases.first { knob in
            guard fxExpanded || ![EditorKnob.delay, .reverb, .chordLevel].contains(knob),
                  let frame = knobFrames[knob], !frame.isEmpty, frame.contains(point) else { return false }
            let radius = min(frame.width, frame.height) / 2
            return hypot(point.x - frame.midX, point.y - frame.midY) <= radius
        }
    }

    private func menuPlacement(_ requested: CGPoint, mode: RadialMode = .primary) -> RadialPlacement? {
        let outerBand: Double = switch mode {
        case .primary: CodaDesignTokens.EditorSurface.radialOuterBand
        case .roots: CodaDesignTokens.EditorSurface.radialInnerBand
        case .all: CodaDesignTokens.EditorSurface.radialFamilyBand
        }
        let outerRadius: Double = switch mode {
        case .primary, .roots: CodaDesignTokens.EditorSurface.radialOuterRadius + outerBand / 2
        case .all: CodaDesignTokens.EditorSurface.radialFamilyRadius + 2 * CodaDesignTokens.EditorSurface.radialFamilySpacing
            + outerBand / 2
        }
        return RadialGeometry.placement(tip: requested, viewport: rootSize,
            outerRadius: outerRadius, margin: CodaDesignTokens.EditorSurface.radialMargin,
            minimumY: chromeHidden ? 0 : Double(stripTop),
            capRadius: outerBand / 2)
    }

    private func setRadialMode(_ mode: RadialMode) {
        guard var state = radial, let placement = menuPlacement(state.anchor, mode: mode) else { return }
        state.mode = mode
        state.placement = placement
        state.selectedRing = nil
        state.selectedSlot = nil
        state.hasNavigated = false
        radial = state
        radialPreview = nil
    }

    private func outerLabels(for state: RadialMenuState) -> [String] {
        let values = suggestions(for: state.regionID)
        return (0..<3).map { index in
            guard values.indices.contains(index) else { return "" }
            return chordNameForSuggestion(values[index].chord)
        } + ["All"]
    }

    private func chordNameForSuggestion(_ chord: Chord) -> String {
        let quality = session.flatMap { try? $0.vocabulary.quality(chord.qualityID).symbol } ?? chord.qualityID
        return "\(Self.pitchNames[chord.root])\(quality)"
    }

    private func updateRadialHover(at point: CGPoint) {
        guard popup == nil else { return }
        guard var state = radial else {
            if var hold = holdMenu {
                hold.selectedIndex = holdMenuLayout?.row(at: point)
                holdMenu = hold
            }
            return
        }
        if !state.hasNavigated {
            guard hypot(point.x - state.anchor.x, point.y - state.anchor.y)
                    >= CodaDesignTokens.Input.holdMoveTolerance else { return }
            state.hasNavigated = true
        }
        guard let hit = radialHit(at: point, state: state) else {
            state.selectedRing = nil
            state.selectedSlot = nil
            radial = state
            radialPreview = nil
            cancelRadialPreview()
            return
        }
        state.selectedRing = hit.0
        state.selectedSlot = hit.1
        radial = state
        radialPreview = radialPreviewText(state)
        if !patternSqueezeMenu { previewRadialChoice(state, hit: hit) }
    }

    func cancelRadialPreview() {
        previewTask?.cancel()
        previewTask = nil
        if let previewOwner { session?.cancelAuditionPreview(owner: previewOwner) }
        previewOwner = nil
        previewChord = nil
    }

    private func previewRadialChoice(_ state: RadialMenuState, hit: (RadialRing, Int)) {
        guard let session, let chord = radialChord(for: hit, state: state) else {
            cancelRadialPreview()
            return
        }
        guard previewChord != chord else { return }
        cancelRadialPreview()
        previewChord = chord
        let owner = UUID()
        previewOwner = owner
        let epoch = session.previewEpoch
        let delay = max(0, CodaDesignTokens.Input.radialPreviewInterval
            - (ProcessInfo.processInfo.systemUptime - lastPreviewTime))
        previewTask = Task { [weak self, weak session] in
            // Coalesce rapidly crossed slots and keep the native mailbox bounded.
            do {
                try await Task.sleep(for: .seconds(delay))
                for attempt in 0..<CodaDesignTokens.Input.previewRetryAttempts {
                    guard !Task.isCancelled, let self, let session,
                          self.popup == nil, self.previewOwner == owner, session.previewEpoch == epoch else { return }
                    do {
                        try session.auditionPreview(chord: chord, owner: owner)
                        self.lastPreviewTime = ProcessInfo.processInfo.systemUptime
                        return
                    } catch AudioSessionError.capacity {
                        if attempt == CodaDesignTokens.Input.previewRetryAttempts - 1 {
                            self.setError("Chord preview is busy."); return
                        }
                        try await Task.sleep(for: .seconds(CodaDesignTokens.Input.previewRetryInterval))
                    } catch {
                        self.setError(error)
                        return
                    }
                }
            } catch { /* superseded hover or cancellation */ }
        }
    }

    private func radialChord(for hit: (RadialRing, Int), state: RadialMenuState) -> Chord? {
        if patternSqueezeMenu { return nil }
        guard let intent = radialIntent(for: hit, state: state) else { return nil }
        let original = regions.first { $0.id == state.regionID }?.chord
        switch intent {
        case .suggestion(let index):
            let values = suggestions(for: state.regionID)
            guard values.indices.contains(index) else { return nil }
            let choice = values[index].chord
            return try? Chord(root: original?.root ?? choice.root, qualityID: choice.qualityID,
                              slashBass: original?.slashBass)
        case .chooseRoot(let root):
            return try? Chord(root: root, qualityID: state.draft?.qualityID ?? original?.qualityID ?? "minor7",
                              slashBass: original?.slashBass)
        case .changeQuality(let id):
            return try? Chord(root: state.swapping ? (state.draft?.root ?? key.tonic) : (original?.root ?? key.tonic),
                              qualityID: id, slashBass: original?.slashBass)
        default: return nil
        }
    }

    private func radialHit(at point: CGPoint, state: RadialMenuState) -> (RadialRing, Int)? {
        let local = CGPoint(x: (point.x - state.center.x) / state.placement.scale,
                            y: (point.y - state.center.y) / state.placement.scale)
        for (ring, labels, radius, thickness) in radialRings() {
            if let slot = RadialGeometry.slot(at: local, count: labels.count, radius: radius,
                                             thickness: thickness, direction: state.placement.direction) {
                return (ring, slot)
            }
        }
        return nil
    }

    private func radialIntent(for hit: (RadialRing, Int), state: RadialMenuState) -> RadialIntent? {
        let suggestionCount = suggestions(for: state.regionID).count
        let qualityIDs: [String]
        switch hit.0 {
        case .major: qualityIDs = qualities(for: .major).map(\.id)
        case .minor: qualityIDs = qualities(for: .minor).map(\.id)
        case .odd: qualityIDs = qualities(for: .odd).map(\.id)
        default: qualityIDs = []
        }
        var slot = hit.1
        let total = hit.0 == .roots ? 12 : qualityIDs.count
        if state.mode != .primary {
            let indices = RadialPage.indices(total: total, page: state.pages[hit.0, default: 0])
            if total > RadialPage.capacity && slot == indices.count { return .nextPage(hit.0) }
            guard slot < indices.count else { return nil }
            slot += indices.lowerBound
        }
        return RadialChoiceResolver.resolve(context: state.context, ring: hit.0, slot: slot,
            suggestionCount: suggestionCount, hasClipboard: clipboard != nil, qualityIDs: qualityIDs)
    }

    private func radialPreviewText(_ state: RadialMenuState) -> String? {
        guard let ring = state.selectedRing, let slot = state.selectedSlot else { return nil }
        if let chord = radialChord(for: (ring, slot), state: state) { return chordNameForSuggestion(chord) }
        if state.mode == .primary {
            if ring == .outer {
                let values = suggestions(for: state.regionID)
                if values.indices.contains(slot) { return chordNameForSuggestion(values[slot].chord) }
                if slot == 3 { return "All qualities" }
            }
            let labels = radialRings().first(where: { $0.0 == ring })?.1 ?? []
            return labels.indices.contains(slot) ? labels[slot] : nil
        }
        let values = radialRings().first(where: { $0.0 == ring })?.1 ?? []
        return values.indices.contains(slot) ? values[slot] : nil
    }

    private func commitRadial(_ state: RadialMenuState, at point: CGPoint) {
        guard popup == nil else { return }
        cancelRadialPreview()
        guard state.hasNavigated || hypot(point.x - state.anchor.x, point.y - state.anchor.y)
                >= CodaDesignTokens.Input.holdMoveTolerance else { closeRadial(); return }
        guard let hit = radialHit(at: point, state: state) else { closeRadial(); return }
        if patternSqueezeMenu {
            radial = nil; patternSqueezeMenu = false
            if patternEditing { endPatternEditing() } else { beginPatternEditing() }
            discardPencilLift = false
            return
        }
        guard let intent = radialIntent(for: hit, state: state) else {
            radial = nil
            return
        }
        visualDetentIntensity = 0.85
        visualDetent += 1
        pencilFeedbackSerial += 1
        pencilFeedbackIsCompletion = true
        transientPoint = point
        switch intent {
        case .nextPage(let ring):
            radial?.pages[ring, default: 0] += 1
            radial?.selectedRing = nil
            radial?.selectedSlot = nil
            radial?.hasNavigated = false
            radialPreview = nil
            return
        case .swapRoot:
            radial?.swapping = true
            setRadialMode(.roots)
            return
        case .duplicate:
            if let id = state.regionID, let region = regions.first(where: { $0.id == id }) { duplicate(region) }
        case .copy:
            if let id = state.regionID { copy(id) }
        case .delete:
            if let id = state.regionID { delete(id) }
        case .paste:
            if let start = state.emptyStart { paste(at: start) }
        case .rest:
            break
        case .suggestion, .changeQuality:
            guard let chord = radialChord(for: hit, state: state) else { closeRadial(); return }
            if let id = state.regionID {
                performMusicAction(.changeQuality) {
                    guard let session = self.session else { return }
                    try session.edit([.swap(id: id, chord: chord)])
                }
            } else if let start = state.emptyStart {
                addChord(chord, at: start, length: MusicDefaults.stepsPerBar)
            }
        case .showAll:
            setRadialMode(.all)
            return
        case .chooseRoot(let root):
            // First lift chooses only the draft root. The quality lift is the
            // sole editor transaction, so cancel/undo cannot expose half a swap.
            radial?.draft?.chooseRoot(root)
            setRadialMode(.all)
            return
        }
        radial = nil
        radialPreview = nil
    }

    private func outerIntentForEmpty(_ index: Int, at start: Int) {
        let values = suggestions(for: nil)
        if values.indices.contains(index) { addChord(values[index].chord, at: start, length: MusicDefaults.stepsPerBar) }
    }

    private func updateSelectionPreview(_ state: RadialMenuState) {
        radialPreview = radialPreviewText(state)
    }

    private func knobDefaultForPreset(_ knob: EditorKnob) -> Double { presetDefault(for: knob) }
}

enum LoopEdge { case start, end }
