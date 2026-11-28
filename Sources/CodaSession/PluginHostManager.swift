import Foundation
import Observation
import AVFoundation
import AudioToolbox
import CoreAudioKit
#if canImport(UIKit)
import UIKit
#endif
import CodaMusic

/// Descriptor for an installed iPadOS AUv3 instrument or imported SoundFont instrument.
public struct HostedPluginDescriptor: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case auv3Instrument
        case soundFont
    }

    public let id: String
    public let name: String
    public let manufacturer: String
    public let kind: Kind
    public let componentType: UInt32
    public let componentSubType: UInt32
    public let componentManufacturer: UInt32
    public let fileURL: URL?

    public init(
        id: String,
        name: String,
        manufacturer: String,
        kind: Kind,
        componentType: UInt32 = 0,
        componentSubType: UInt32 = 0,
        componentManufacturer: UInt32 = 0,
        fileURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.kind = kind
        self.componentType = componentType
        self.componentSubType = componentSubType
        self.componentManufacturer = componentManufacturer
        self.fileURL = fileURL
    }

    public var audioComponentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: componentType,
            componentSubType: componentSubType,
            componentManufacturer: componentManufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }
}

public enum PluginHostMode: String, Codable, Hashable, Sendable, CaseIterable {
    case builtInSynth
    case auv3Plugin
    case soundFont
}

/// Hosts iPadOS AUv3 instrument plugins (iPadOS VST equivalent) and imported `.sf2`/`.dls` SoundFonts per layer.
@MainActor
@Observable
public final class PluginHostManager {
    public private(set) var availableInstruments: [HostedPluginDescriptor] = []
    public private(set) var importedSoundFonts: [HostedPluginDescriptor] = []
    public private(set) var activeModeByLayer: [MusicLayer: PluginHostMode] = [
        .chords: .builtInSynth,
        .bass: .builtInSynth,
        .melody: .builtInSynth
    ]
    public private(set) var activePluginByLayer: [MusicLayer: HostedPluginDescriptor] = [:]
    public private(set) var isScanning: Bool = false
    public private(set) var lastStatusMessage: String?
    public private(set) var lastError: String?

    @ObservationIgnored private var hostEngine: AVAudioEngine?
    @ObservationIgnored private var loadedUnits: [MusicLayer: AVAudioUnit] = [:]
    @ObservationIgnored private let soundFontDirectory: URL

    public init(soundFontDirectory: URL? = nil) {
        if let soundFontDirectory {
            self.soundFontDirectory = soundFontDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.soundFontDirectory = appSupport
                .appendingPathComponent("coda", isDirectory: true)
                .appendingPathComponent("plugins", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.soundFontDirectory, withIntermediateDirectories: true)
        refreshImportedSoundFonts()
    }

    public func mode(for layer: MusicLayer) -> PluginHostMode {
        activeModeByLayer[layer] ?? .builtInSynth
    }

    public func setMode(_ mode: PluginHostMode, for layer: MusicLayer) {
        activeModeByLayer[layer] = mode
        if mode == .builtInSynth {
            unloadPlugin(for: layer)
        }
    }

    public func activePlugin(for layer: MusicLayer) -> HostedPluginDescriptor? {
        activePluginByLayer[layer]
    }

    /// Scan all installed iPadOS AUv3 MusicDevice instruments via `AVAudioUnitComponentManager`.
    public func scanAvailablePlugins() {
        isScanning = true
        lastError = nil
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let components = AVAudioUnitComponentManager.shared().components(matching: description)
        availableInstruments = components.map { component in
            let desc = component.audioComponentDescription
            let id = "\(desc.componentType)-\(desc.componentSubType)-\(desc.componentManufacturer)"
            return HostedPluginDescriptor(
                id: id,
                name: component.name,
                manufacturer: component.manufacturerName,
                kind: .auv3Instrument,
                componentType: desc.componentType,
                componentSubType: desc.componentSubType,
                componentManufacturer: desc.componentManufacturer
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        isScanning = false
        lastStatusMessage = availableInstruments.isEmpty
            ? "No AUv3 instruments installed on this iPad yet. Install any AUv3 synth app or import a .sf2/.dls instrument."
            : "Found \(availableInstruments.count) AUv3 instrument(s)."
    }

    public func refreshImportedSoundFonts() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: soundFontDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            importedSoundFonts = []
            return
        }
        let exts: Set<String> = ["sf2", "dls", "aupreset"]
        importedSoundFonts = files
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .map { url in
                HostedPluginDescriptor(
                    id: "sf:\(url.lastPathComponent)",
                    name: url.deletingPathExtension().lastPathComponent,
                    manufacturer: url.pathExtension.uppercased(),
                    kind: .soundFont,
                    fileURL: url
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Copy an external `.sf2` / `.dls` instrument into Application Support and load it into `AVAudioUnitSampler`.
    @discardableResult
    public func importSoundFont(from sourceURL: URL, for layer: MusicLayer) throws -> HostedPluginDescriptor {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let ext = sourceURL.pathExtension.lowercased()
        guard ["sf2", "dls", "aupreset"].contains(ext) else {
            let err = NSError(
                domain: "com.coda.pluginhost",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported plugin file .\(ext). Use iPadOS AUv3 plugins or .sf2/.dls SoundFont instruments."]
            )
            lastError = err.localizedDescription
            throw err
        }

        try FileManager.default.createDirectory(at: soundFontDirectory, withIntermediateDirectories: true)
        let destURL = soundFontDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        refreshImportedSoundFonts()

        let descriptor = HostedPluginDescriptor(
            id: "sf:\(destURL.lastPathComponent)",
            name: destURL.deletingPathExtension().lastPathComponent,
            manufacturer: ext.uppercased(),
            kind: .soundFont,
            fileURL: destURL
        )
        try loadSoundFont(descriptor, for: layer)
        return descriptor
    }

    public func loadSoundFont(_ descriptor: HostedPluginDescriptor, for layer: MusicLayer) throws {
        guard let url = descriptor.fileURL else { return }
        unloadPlugin(for: layer)
        let engine = ensureEngine()
        let sampler = AVAudioUnitSampler()
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        try sampler.loadSoundBankInstrument(
            at: url,
            program: 0,
            bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
            bankLSB: UInt8(kAUSampler_DefaultBankLSB)
        )
        if !engine.isRunning {
            try? engine.start()
        }
        loadedUnits[layer] = sampler
        activePluginByLayer[layer] = descriptor
        activeModeByLayer[layer] = .soundFont
        lastStatusMessage = "Loaded \(descriptor.name) on \(layer.rawValue.capitalized)."
        lastError = nil
    }

    /// Instantiate an installed AUv3 instrument out-of-process and attach it to the host `AVAudioEngine`.
    public func loadAUv3Plugin(_ descriptor: HostedPluginDescriptor, for layer: MusicLayer) async {
        unloadPlugin(for: layer)
        lastError = nil
        do {
            let unit = try await AVAudioUnit.instantiate(
                with: descriptor.audioComponentDescription,
                options: .loadOutOfProcess
            )
            let engine = ensureEngine()
            engine.attach(unit)
            engine.connect(unit, to: engine.mainMixerNode, format: nil)
            if !engine.isRunning {
                try? engine.start()
            }
            loadedUnits[layer] = unit
            activePluginByLayer[layer] = descriptor
            activeModeByLayer[layer] = .auv3Plugin
            lastStatusMessage = "Loaded AUv3 \(descriptor.name) on \(layer.rawValue.capitalized)."
        } catch {
            lastError = "Failed to load \(descriptor.name): \(error.localizedDescription)"
        }
    }

    public func unloadPlugin(for layer: MusicLayer) {
        if let unit = loadedUnits.removeValue(forKey: layer), let engine = hostEngine {
            engine.detach(unit)
        }
        activePluginByLayer.removeValue(forKey: layer)
    }

    /// Audition MIDI notes through a hosted AUv3 or SoundFont instrument if active on `layer`.
    public func auditionHostedNote(pitch: UInt8, velocity: UInt8 = 100, layer: MusicLayer) {
        guard let unit = loadedUnits[layer] else { return }
        if let sampler = unit as? AVAudioUnitSampler {
            sampler.startNote(pitch, withVelocity: velocity, onChannel: 0)
            Task {
                try? await Task.sleep(for: .milliseconds(380))
                sampler.stopNote(pitch, onChannel: 0)
            }
        } else if let midiBlock = unit.auAudioUnit.scheduleMIDIEventBlock {
            var noteOn: [UInt8] = [0x90, pitch, velocity]
            midiBlock(AUEventSampleTimeImmediate, 0, 3, &noteOn)
            Task {
                try? await Task.sleep(for: .milliseconds(380))
                var noteOff: [UInt8] = [0x80, pitch, 0]
                midiBlock(AUEventSampleTimeImmediate, 0, 3, &noteOff)
            }
        }
    }

    #if canImport(UIKit)
    /// Request the native AUv3 plugin UI view controller to embed inside CODA's bottom rack.
    public func requestPluginViewController(for layer: MusicLayer) async -> UIViewController? {
        guard let unit = loadedUnits[layer] else { return nil }
        return await withCheckedContinuation { continuation in
            unit.auAudioUnit.requestViewController { vc in
                continuation.resume(returning: vc)
            }
        }
    }
    #endif

    private func ensureEngine() -> AVAudioEngine {
        if let hostEngine { return hostEngine }
        let engine = AVAudioEngine()
        hostEngine = engine
        return engine
    }
}
