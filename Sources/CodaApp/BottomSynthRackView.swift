import SwiftUI
import CodaMusic
import CodaSession

enum SynthRackTab: String, CaseIterable, Identifiable {
    case codaSynth
    case auv3Plugins
    case importSoundFont

    var id: String { rawValue }
    var title: String {
        switch self {
        case .codaSynth: "CODA Synth"
        case .auv3Plugins: "AUv3 Plugins"
        case .importSoundFont: "Import (.sf2/.dls)"
        }
    }
}

/// FL-style Bottom VST Synth & Plugin Rack rising up to 50% of screen height.
struct BottomSynthRackView: View {
    @Bindable var store: CodaEditorStore

    var body: some View {
        VStack(spacing: 0) {
            rackHeader
                .padding(.horizontal, 18)
                .frame(height: 44)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(CodaDesignTokens.ProcreateChrome.divider).frame(height: 0.5)
                }

            ScrollView {
                switch store.synthRackTab {
                case .codaSynth:
                    codaSynthContent
                case .auv3Plugins:
                    auv3PluginsContent
                case .importSoundFont:
                    soundFontImportContent
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("drawer.synthScroll")
        }
        .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
        .background { CodaAcrylic(store: store) }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
        .shadow(color: CodaDesignTokens.ProcreateChrome.shadowColor, radius: 22, y: -6)
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.bottomSynthRack")
    }

    private var rackHeader: some View {
        HStack(spacing: 12) {
            // Active track badge
            HStack(spacing: 6) {
                Circle().fill(store.activeTrackColor).frame(width: 7, height: 7)
                Text(store.activeTrackDisplayName.uppercased())
                    .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                    .foregroundStyle(store.activeTrackColor)
            }
            .padding(.horizontal, 9).frame(height: 26)
            .background(store.activeTrackColor.opacity(0.12), in: Capsule())

            // Mode tabs
            HStack(spacing: 4) {
                ForEach(SynthRackTab.allCases) { tab in
                    let selected = store.synthRackTab == tab
                    Button {
                        store.synthRackTab = tab
                    } label: {
                        Text(tab.title)
                            .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                            .foregroundStyle(selected ? CodaDesignTokens.Colors.primaryInk : CodaDesignTokens.Colors.mutedInk)
                            .padding(.horizontal, 11).frame(height: 28)
                            .background(selected ? CodaDesignTokens.ProcreateChrome.activePillFill : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .accessibilityIdentifier("synthRack.tab.\(tab.rawValue)")
                }
            }
            .padding(2)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

            Spacer()

            Button {
                store.toggleSynthRack(false)
            } label: {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel("Close synth rack")
            .accessibilityIdentifier("synthRack.close")
        }
    }

    // MARK: - CODA Synth Tab

    private var codaSynthContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                // Left column: Presets + Macros
                VStack(alignment: .leading, spacing: 14) {
                    sectionLabel("PRESETS")
                    HStack(spacing: 8) {
                        presetCard("Pluck", index: 0)
                        presetCard("Currents Pad", index: 1)
                        presetCard("Wobble Lead", index: 2)
                    }
                    .frame(height: 52)

                    sectionLabel("MACROS")
                    HStack(spacing: 16) {
                        RackKnobControl(store: store, knob: .wobble, diameter: CodaDesignTokens.EditorSurface.drawerMacroDiameter)
                        RackKnobControl(store: store, knob: .warmth, diameter: CodaDesignTokens.EditorSurface.drawerMacroDiameter)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Middle column: 5 Sound Knobs
                VStack(alignment: .leading, spacing: 14) {
                    sectionLabel("SOUND ENGINE")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 14) {
                        ForEach([EditorKnob.cutoff, .resonance, .shape, .detune, .glide]) { knob in
                            RackKnobControl(store: store, knob: knob, diameter: CodaDesignTokens.EditorSurface.drawerKnobDiameter)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right column: Post-FX Rack (Chorus, Delay, Reverb) + Mixer
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        sectionLabel("POST-FX RACK")
                        Spacer()
                        Button {
                            store.fxExpanded.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Text("FX & Mix")
                                    .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                                Image(systemName: store.fxExpanded ? "minus.circle.fill" : "plus.circle.fill")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(.white.opacity(0.07), in: Capsule())
                        }
                        .accessibilityIdentifier("drawer.fxMix")
                        .accessibilityValue(store.fxExpanded ? "expanded" : "collapsed")
                    }

                    HStack(spacing: 10) {
                        RackKnobControl(store: store, knob: .chorus, diameter: CodaDesignTokens.EditorSurface.drawerKnobDiameter)
                        RackKnobControl(store: store, knob: .delay, diameter: CodaDesignTokens.EditorSurface.drawerKnobDiameter)
                        RackKnobControl(store: store, knob: .reverb, diameter: CodaDesignTokens.EditorSurface.drawerKnobDiameter)
                    }

                    if store.fxExpanded {
                        HStack(spacing: 10) {
                            RackKnobControl(store: store, knob: .chordLevel, diameter: CodaDesignTokens.EditorSurface.drawerKnobDiameter)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rectangle().fill(CodaDesignTokens.ProcreateChrome.divider).frame(height: 0.5)

            // Per-layer / track mixer strip
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("TRACK MIXER")
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach([MusicLayer.bass, .chords, .melody], id: \.self) { layer in
                            baseLayerMixerChannel(layer)
                        }
                        ForEach(store.extraLayers) { extra in
                            extraLayerMixerChannel(extra)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            if let error = store.audioError, !error.isEmpty {
                Text("Audio: \(error)")
                    .font(CodaDesignTokens.Typography.font(size: 10, weight: .semibold))
                    .foregroundStyle(CodaDesignTokens.Colors.danger)
                    .accessibilityIdentifier("drawer.audioError")
            }
        }
        .padding(18)
    }

    private func presetCard(_ title: String, index: UInt8) -> some View {
        let selected = store.activeLayerPreset == index
        return Button { store.setPreset(index) } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(selected ? store.activeTrackColor : CodaDesignTokens.Colors.mutedInk.opacity(0.25))
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? CodaDesignTokens.Colors.primaryInk : CodaDesignTokens.Colors.mutedInk)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 6)
            .background(.white.opacity(selected ? 0.13 : 0.045),
                        in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card))
        }
        .accessibilityIdentifier("drawer.preset.\(index)")
        .accessibilityValue(selected ? "selected" : "")
    }

    private func baseLayerMixerChannel(_ layer: MusicLayer) -> some View {
        let muted = store.isLayerMuted(layer)
        let level = store.layerLevel(layer)
        let active = store.activeExtraLayerID == nil && store.activeLayer == layer
        return VStack(spacing: 8) {
            Button {
                store.selectBaseLayer(layer)
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(layer.accentColor).frame(width: 6, height: 6)
                    Text(layer.displayName)
                        .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                }
                .foregroundStyle(active ? CodaDesignTokens.Colors.primaryInk : CodaDesignTokens.Colors.mutedInk)
            }

            HStack(spacing: 6) {
                Button {
                    store.toggleLayerMute(layer)
                } label: {
                    Text("M")
                        .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                        .foregroundStyle(muted ? Color.black : CodaDesignTokens.Colors.mutedInk)
                        .frame(width: 24, height: 22)
                        .background(muted ? CodaDesignTokens.Colors.danger : .white.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 4))
                }
                Button {
                    store.soloBaseLayer(layer)
                } label: {
                    Text("S")
                        .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                        .frame(width: 24, height: 22)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                }
            }

            Slider(value: Binding(
                get: { level },
                set: { store.setLayerLevel($0, for: layer) }
            ), in: 0...1)
            .tint(layer.accentColor)
            .frame(width: 110)

            Text("\(Int((level * 100).rounded()))%")
                .font(CodaDesignTokens.Typography.font(size: 10, weight: .semibold))
                .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
        }
        .padding(10)
        .background(.white.opacity(active ? 0.08 : 0.035),
                    in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card))
    }

    private func extraLayerMixerChannel(_ extra: ExtraLayerTrack) -> some View {
        let active = store.activeExtraLayerID == extra.id
        return VStack(spacing: 8) {
            Button {
                store.selectExtraLayer(id: extra.id)
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(extra.kind.accentColor).frame(width: 6, height: 6)
                    Text(extra.name)
                        .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                        .lineLimit(1)
                }
                .foregroundStyle(active ? CodaDesignTokens.Colors.primaryInk : CodaDesignTokens.Colors.mutedInk)
            }

            HStack(spacing: 6) {
                Button {
                    store.setExtraLayerMuted(!extra.muted, for: extra.id)
                } label: {
                    Text("M")
                        .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                        .foregroundStyle(extra.muted ? Color.black : CodaDesignTokens.Colors.mutedInk)
                        .frame(width: 24, height: 22)
                        .background(extra.muted ? CodaDesignTokens.Colors.danger : .white.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 4))
                }
                Button {
                    store.removeExtraLayer(id: extra.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.danger)
                        .frame(width: 24, height: 22)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                }
            }

            Slider(value: Binding(
                get: { Double(extra.layerControls.level) },
                set: { newVal in
                    var updated = extra.layerControls
                    updated.level = Float(newVal)
                    store.setExtraLayerControls(updated, for: extra.id)
                }
            ), in: 0...1)
            .tint(extra.kind.accentColor)
            .frame(width: 110)

            Text("\(Int((Double(extra.layerControls.level) * 100).rounded()))%")
                .font(CodaDesignTokens.Typography.font(size: 10, weight: .semibold))
                .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
        }
        .padding(10)
        .background(.white.opacity(active ? 0.08 : 0.035),
                    in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card))
    }

    // MARK: - AUv3 Plugins Tab

    private var auv3PluginsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("iPadOS AUv3 Instrument Host")
                        .font(CodaDesignTokens.Typography.font(size: 14, weight: .bold))
                    Text("iPadOS hosts native AUv3 plugins. Desktop .vst3 binaries cannot execute directly on iPadOS; use AUv3 apps or .sf2/.dls imports.")
                        .font(CodaDesignTokens.Typography.font(size: 11, weight: .medium))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                }
                Spacer()
                Button {
                    store.pluginHost.scanAvailablePlugins()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold))
                        Text(store.pluginHost.isScanning ? "Scanning…" : "Scan AUv3")
                            .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                    }
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(.white.opacity(0.10), in: Capsule())
                }
                .accessibilityIdentifier("synthRack.scanAUv3")
            }

            if let status = store.pluginHost.lastStatusMessage {
                Text(status)
                    .font(CodaDesignTokens.Typography.font(size: 11, weight: .medium))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
            }
            if let error = store.pluginHost.lastError {
                Text(error)
                    .font(CodaDesignTokens.Typography.font(size: 11, weight: .semibold))
                    .foregroundStyle(CodaDesignTokens.Colors.danger)
            }

            let activePlugin = store.pluginHost.activePlugin(for: store.activeLayer)
            if store.pluginHost.availableInstruments.isEmpty {
                Text("Tap Scan AUv3 to discover installed iPadOS AUv3 synth & instrument extensions.")
                    .font(CodaDesignTokens.Typography.font(size: 12, weight: .medium))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card))
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(store.pluginHost.availableInstruments) { plugin in
                        let isLoaded = activePlugin?.id == plugin.id
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plugin.name)
                                    .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                                    .lineLimit(1)
                                Text(plugin.manufacturer)
                                    .font(CodaDesignTokens.Typography.font(size: 10, weight: .medium))
                                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                if isLoaded {
                                    store.pluginHost.setMode(.builtInSynth, for: store.activeLayer)
                                    if let extraID = store.activeExtraLayerID {
                                        store.setExtraLayerPlugin(nil, for: extraID)
                                    }
                                } else {
                                    Task {
                                        await store.pluginHost.loadAUv3Plugin(plugin, for: store.activeLayer)
                                        if let extraID = store.activeExtraLayerID {
                                            store.setExtraLayerPlugin(plugin.name, for: extraID)
                                        }
                                    }
                                }
                            } label: {
                                Text(isLoaded ? "Unload" : "Load")
                                    .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                                    .foregroundStyle(isLoaded ? CodaDesignTokens.Colors.danger : CodaDesignTokens.Colors.primaryInk)
                                    .padding(.horizontal, 10).frame(height: 26)
                                    .background(.white.opacity(isLoaded ? 0.06 : 0.12), in: Capsule())
                            }
                        }
                        .padding(10)
                        .background(.white.opacity(isLoaded ? 0.09 : 0.04),
                                    in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card))
                    }
                }
            }
        }
        .padding(18)
    }

    // MARK: - SoundFont Import Tab

    private var soundFontImportContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Imported SoundFonts (.sf2 / .dls)")
                        .font(CodaDesignTokens.Typography.font(size: 14, weight: .bold))
                    Text("Import SoundFont banks from Files and assign them to \(store.activeTrackDisplayName).")
                        .font(CodaDesignTokens.Typography.font(size: 11, weight: .medium))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                }
                Spacer()
                Button {
                    CodaUIKitFilePresenter.presentSoundFontImporter { url in
                        Task { @MainActor in
                            store.importSoundFont(from: url)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 12, weight: .bold))
                        Text("Import .sf2 / .dls")
                            .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(CodaDesignTokens.Colors.primaryInk, in: Capsule())
                }
                .accessibilityIdentifier("synthRack.importSF2")
            }

            if store.pluginHost.importedSoundFonts.isEmpty {
                Text("No .sf2 or .dls instruments imported yet.")
                    .font(CodaDesignTokens.Typography.font(size: 12, weight: .medium))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card))
            } else {
                let activePlugin = store.pluginHost.activePlugin(for: store.activeLayer)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(store.pluginHost.importedSoundFonts) { sf in
                        let isLoaded = activePlugin?.id == sf.id
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sf.name)
                                    .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                                    .lineLimit(1)
                                Text(sf.manufacturer)
                                    .font(CodaDesignTokens.Typography.font(size: 10, weight: .semibold))
                                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                            }
                            Spacer()
                            Button {
                                if isLoaded {
                                    store.pluginHost.setMode(.builtInSynth, for: store.activeLayer)
                                    if let extraID = store.activeExtraLayerID {
                                        store.setExtraLayerPlugin(nil, for: extraID)
                                    }
                                } else {
                                    do {
                                        try store.pluginHost.loadSoundFont(sf, for: store.activeLayer)
                                        if let extraID = store.activeExtraLayerID {
                                            store.setExtraLayerPlugin(sf.name, for: extraID)
                                        }
                                    } catch {
                                        store.inlineError = error.localizedDescription
                                    }
                                }
                            } label: {
                                Text(isLoaded ? "Clear" : "Assign")
                                    .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                                    .foregroundStyle(isLoaded ? CodaDesignTokens.Colors.danger : CodaDesignTokens.Colors.primaryInk)
                                    .padding(.horizontal, 10).frame(height: 26)
                                    .background(.white.opacity(isLoaded ? 0.06 : 0.12), in: Capsule())
                            }
                        }
                        .padding(10)
                        .background(.white.opacity(isLoaded ? 0.09 : 0.04),
                                    in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card))
                    }
                }
            }
        }
        .padding(18)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(CodaDesignTokens.Typography.font(size: 10, weight: .black))
            .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
    }
}

/// Shared rotary knob control used by the Bottom Synth Rack (and compatible with `KnobFramesKey`).
struct RackKnobControl: View {
    @Bindable var store: CodaEditorStore
    let knob: EditorKnob
    let diameter: CGFloat
    @State private var dragStart: Double?

    private var value: Double { store.value(for: knob) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().trim(from: 0.125, to: 0.875)
                    .stroke(.white.opacity(0.10), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Circle().trim(from: 0.125, to: 0.125 + 0.75 * value)
                    .stroke(store.activeTrackColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Circle().fill(CodaDesignTokens.Colors.primaryInk.opacity(0.75))
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Center dot")
                    .accessibilityIdentifier("drawer.knob.dot.\(knob.rawValue)")
            }
            .frame(width: diameter, height: diameter)
            .background(.white.opacity(0.04), in: Circle())
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: KnobFramesKey.self,
                        value: [knob: geometry.frame(in: .named("editor.root"))])
                }
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                if dragStart == nil { dragStart = value }
                guard let dragStart else { return }
                store.setValue(dragStart - Double(gesture.translation.height) / 140, for: knob)
            }.onEnded { _ in dragStart = nil })
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("drawer.knob.dial.\(knob.rawValue)")

            HStack(spacing: 4) {
                Text(knob.title)
                    .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text("\(Int((value * 100).rounded()))")
                    .font(CodaDesignTokens.Typography.font(size: CodaDesignTokens.Typography.chipAndReadoutSize, weight: .bold))
                    .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
                    .fixedSize()
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.white.opacity(0.08), in: Capsule())
                    .accessibilityIdentifier("drawer.knob.readout.\(knob.rawValue)")
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(knob.title)
        .accessibilityValue("\(Int((value * 100).rounded())) percent; preset default \(Int((store.presetDefault(for: knob) * 100).rounded())) percent")
        .accessibilityIdentifier("drawer.knob.\(knob.rawValue)")
    }
}
