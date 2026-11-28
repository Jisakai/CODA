import Foundation
import Observation

/// Apple Pencil Pro double-tap action options (Procreate-style Gesture Controls).
public enum PencilDoubleTapAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case toggleDrawErase
    case togglePlayPause
    case toggleSynthRack
    case toggleSidekick
    case undo
    case cycleLayer
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .toggleDrawErase: "Draw / Razor"
        case .togglePlayPause: "Play / Pause"
        case .toggleSynthRack: "Synth Rack"
        case .toggleSidekick: "AI Sidekick"
        case .undo: "Undo"
        case .cycleLayer: "Cycle Layer"
        case .off: "Off"
        }
    }

    public var symbol: String {
        switch self {
        case .toggleDrawErase: "pencil.and.outline"
        case .togglePlayPause: "playpause.fill"
        case .toggleSynthRack: "slider.horizontal.3"
        case .toggleSidekick: "sparkles"
        case .undo: "arrow.uturn.backward"
        case .cycleLayer: "square.3.layers.3d"
        case .off: "nosign"
        }
    }
}

/// Apple Pencil Pro squeeze action options.
public enum PencilSqueezeAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case radialPalette
    case chordPicker
    case toggleSynthRack
    case toggleSidekick
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .radialPalette: "Radial Palette"
        case .chordPicker: "Chord Picker"
        case .toggleSynthRack: "Synth Rack"
        case .toggleSidekick: "AI Sidekick"
        case .off: "Off"
        }
    }

    public var symbol: String {
        switch self {
        case .radialPalette: "circle.hexagongrid.fill"
        case .chordPicker: "music.note.list"
        case .toggleSynthRack: "slider.horizontal.3"
        case .toggleSidekick: "sparkles"
        case .off: "nosign"
        }
    }
}

/// Apple Pencil Pro barrel roll behavior mode.
public enum BarrelRollMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case voicingAndNudge
    case filterCutoff
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .voicingAndNudge: "Voicing & Nudge"
        case .filterCutoff: "Filter Cutoff"
        case .off: "Off"
        }
    }

    public var symbol: String {
        switch self {
        case .voicingAndNudge: "arrow.triangle.2.circlepath"
        case .filterCutoff: "dial.medium.fill"
        case .off: "nosign"
        }
    }
}

/// Procreate-style Gesture Controls persisted to `UserDefaults`.
@MainActor
@Observable
public final class GestureSettings {
    private enum Keys {
        static let pencilDoubleTap = "coda.gestures.pencilDoubleTap"
        static let pencilSqueeze = "coda.gestures.pencilSqueeze"
        static let barrelRoll = "coda.gestures.barrelRoll"
        static let twoFingerTapUndo = "coda.gestures.twoFingerTapUndo"
        static let threeFingerTapRedo = "coda.gestures.threeFingerTapRedo"
        static let holdMenuDelayMs = "coda.gestures.holdMenuDelayMs"
        static let hapticsEnabled = "coda.gestures.hapticsEnabled"
    }

    @ObservationIgnored private let defaults: UserDefaults

    public var pencilDoubleTap: PencilDoubleTapAction {
        didSet { defaults.set(pencilDoubleTap.rawValue, forKey: Keys.pencilDoubleTap) }
    }

    public var pencilSqueeze: PencilSqueezeAction {
        didSet { defaults.set(pencilSqueeze.rawValue, forKey: Keys.pencilSqueeze) }
    }

    public var barrelRoll: BarrelRollMode {
        didSet { defaults.set(barrelRoll.rawValue, forKey: Keys.barrelRoll) }
    }

    public var twoFingerTapUndo: Bool {
        didSet { defaults.set(twoFingerTapUndo, forKey: Keys.twoFingerTapUndo) }
    }

    public var threeFingerTapRedo: Bool {
        didSet { defaults.set(threeFingerTapRedo, forKey: Keys.threeFingerTapRedo) }
    }

    public var holdMenuDelayMs: Double {
        didSet { defaults.set(holdMenuDelayMs, forKey: Keys.holdMenuDelayMs) }
    }

    public var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Keys.hapticsEnabled) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.pencilDoubleTap = PencilDoubleTapAction(rawValue: defaults.string(forKey: Keys.pencilDoubleTap) ?? "") ?? .toggleDrawErase
        self.pencilSqueeze = PencilSqueezeAction(rawValue: defaults.string(forKey: Keys.pencilSqueeze) ?? "") ?? .radialPalette
        self.barrelRoll = BarrelRollMode(rawValue: defaults.string(forKey: Keys.barrelRoll) ?? "") ?? .voicingAndNudge
        self.twoFingerTapUndo = defaults.object(forKey: Keys.twoFingerTapUndo) as? Bool ?? true
        self.threeFingerTapRedo = defaults.object(forKey: Keys.threeFingerTapRedo) as? Bool ?? true
        let storedDelay = defaults.object(forKey: Keys.holdMenuDelayMs) as? Double ?? 320
        self.holdMenuDelayMs = min(800, max(150, storedDelay))
        self.hapticsEnabled = defaults.object(forKey: Keys.hapticsEnabled) as? Bool ?? true
    }

    public func resetDefaults() {
        pencilDoubleTap = .toggleDrawErase
        pencilSqueeze = .radialPalette
        barrelRoll = .voicingAndNudge
        twoFingerTapUndo = true
        threeFingerTapRedo = true
        holdMenuDelayMs = 320
        hapticsEnabled = true
    }
}
