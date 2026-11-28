import SwiftUI
import UIKit
import CodaMusic
import CodaSession
import CodaInteraction
import CodaSidekick

struct KnobFramesKey: PreferenceKey {
    static let defaultValue: [EditorKnob: CGRect] = [:]
    static func reduce(value: inout [EditorKnob: CGRect], nextValue: () -> [EditorKnob: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

struct CodaCanvas: View {
    @Bindable var store: CodaEditorStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsFrames: [EditorPopup: CGRect] = [:]
    @State private var popupSize = PopupSizeKey.defaultValue

    var body: some View {
        // Register these dependencies on the State-owning view before building
        // GeometryReader's deferred content. With only a conditional read below,
        // popup == nil skips settingsFrames: the first preference delivery can
        // leave that closure holding the initial empty State value. A later
        // observable popup change alone then cannot pass the anchor gate.
        let frames = settingsFrames
        let measuredPopupSize = popupSize
        let activePopup = store.popup
        return GeometryReader { geometry in
            let rackHeight = min(geometry.size.height * 0.50, 460)
            ZStack(alignment: .topLeading) {
                CodaDesignTokens.Colors.oled
                if store.chromeHidden {
                    PianoRollView(store: store)
                        .frame(height: max(0, geometry.size.height - store.rollTop))
                        .offset(y: 0)
                } else {
                    VStack(spacing: 0) {
                        EditorTopBar(store: store)
                        TimelineStripView(store: store)
                        ChordStripView(store: store)
                        PianoRollView(store: store)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    if store.drawerOpen {
                        SynthDrawer(store: store)
                            .frame(width: store.drawerWidth,
                                   height: max(0, geometry.size.height - store.drawerTop))
                            .offset(x: geometry.size.width - store.drawerWidth, y: store.drawerTop)
                            .transition(.move(edge: .trailing))
                            .zIndex(4)
                    }
                    DrawerPullTab(store: store)
                        .position(x: geometry.size.width - (store.drawerOpen ? store.drawerWidth : 0)
                                  + (store.drawerOpen ? 1 : -1) * CodaDesignTokens.EditorSurface.drawerTabWidth / 2,
                                  y: (store.drawerTop + geometry.size.height) / 2)
                        .zIndex(5)

                    if store.synthRackOpen {
                        BottomSynthRackView(store: store)
                            .frame(width: geometry.size.width, height: rackHeight)
                            .offset(x: 0, y: geometry.size.height - rackHeight)
                            .transition(.move(edge: .bottom))
                            .zIndex(6)
                    }
                    SynthRackPullTab(store: store)
                        .position(x: geometry.size.width / 2,
                                  y: geometry.size.height - (store.synthRackOpen ? rackHeight + 10 : 12))
                        .zIndex(7)
                }

                if store.patternEditing {
                    PatternOverlayView(store: store)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .zIndex(3)
                        // Apply paint-only semantics outside the layout wrappers too.
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                if store.radial != nil, let center = store.radialCenter {
                    RadialMenuView(store: store, center: center, mode: store.radialModeName ?? "primary")
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityIdentifier("radial.menu.\(store.radialModeName ?? "primary")")
                        .zIndex(8)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: UnitPoint(x: center.x / max(1, geometry.size.width), y: center.y / max(1, geometry.size.height)))))
                } else if let preview = store.radialPreview {
                    // Voicing-roll / melody-nudge HUD when radial menu is closed
                    Text(preview)
                        .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background { CodaAcrylic(store: store).clipShape(Capsule()) }
                        .position(x: min(geometry.size.width - 72, max(72, (store.transientPoint?.x ?? geometry.size.width / 2))),
                                  y: max(store.stripTop + 26, (store.transientPoint?.y ?? store.stripTop + 44) - 34))
                        .allowsHitTesting(false)
                        .zIndex(8)
                }

                if let layout = store.holdMenuLayout {
                    HoldMenuView(store: store)
                        .frame(width: layout.frame.width, height: layout.frame.height, alignment: .topLeading)
                        .offset(x: layout.frame.minX, y: layout.frame.minY)
                        .zIndex(9)
                }

                if let reset = store.knobReset {
                    KnobResetMenu(store: store, state: reset)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .zIndex(10)
                }

                if let readout = store.knobReadout, let point = store.transientPoint {
                    Text(readout)
                        .font(CodaDesignTokens.Typography.font(size: CodaDesignTokens.Typography.chipAndReadoutSize,
                                                               weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background { CodaAcrylic(store: store).clipShape(Capsule()) }
                        .position(x: min(geometry.size.width - 52, max(52, point.x + 58)),
                                  y: min(geometry.size.height - 20, max(18, point.y - 28)))
                        .allowsHitTesting(false)
                        .zIndex(11)
                }

                if store.visualDetent > 0, let point = store.transientPoint {
                    let strong = store.visualDetentIntensity > 0.5
                    let size = strong ? CodaDesignTokens.Geometry.strongDetentDotSize : CodaDesignTokens.Geometry.detentDotSize
                    Circle().fill(CodaDesignTokens.Colors.primaryInk.opacity(strong ? 0.7 : 0.35))
                        .frame(width: size, height: size)
                        .position(point)
                        .allowsHitTesting(false)
                        .zIndex(12)
                }

                EditorInlineStatus(store: store)
                    .position(x: geometry.size.width / 2, y: store.rollTop + 16)
                    .zIndex(13)

                if let popup = activePopup, let anchor = frames[popup] ?? frames[.appSettings] {
                    let frame = AnchoredPopupLayout.frame(anchor: anchor, size: measuredPopupSize, viewport: geometry.size,
                        gap: CodaDesignTokens.EditorSurface.popupGap)
                    Color.black.opacity(0.001).contentShape(Rectangle())
                        .onTapGesture { location in
                            store.recordUIEvent("popup.dismiss.backdrop at=\(location)")
                            store.popup = nil
                        }
                        .zIndex(19)
                    EditorSettingsPopover(store: store, popup: popup)
                        .fixedSize(horizontal: false, vertical: true)
                        .background { GeometryReader { measured in
                            Color.clear.preference(key: PopupSizeKey.self, value: measured.size)
                        } }
                        .modifier(AcrylicPanel(store: store))
                        // Observe the panel inside the transform: an observer
                        // outside offset sees its untranslated layout wrapper.
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("editor.root")) } action: {
                            store.recordPopupFrame($0, popup: popup)
                        }
                        .offset(x: frame.minX, y: frame.minY)
                        .onAppear { store.recordUIEvent("popup.appear.\(popup.rawValue)") }
                        .onDisappear { store.recordUIEvent("popup.disappear.\(popup.rawValue)") }
                        .zIndex(20)
                }

                if store.projectHubOpen {
                    ProjectHubView(store: store)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .transition(.opacity)
                        .zIndex(30)
                }

                PencilInputBridge(store: store, onPencilDoubleTap: { store.handlePencilDoubleTap() })
                    .frame(width: 1, height: 1)
                    .position(x: -2, y: -2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .coordinateSpace(name: "editor.root")
            .onPreferenceChange(SettingsFramesKey.self) {
                settingsFrames = $0
                store.recordSettingsFrames($0, stage: "root")
            }
            .onPreferenceChange(PopupSizeKey.self) { popupSize = $0 }
            .onPreferenceChange(KnobFramesKey.self) { store.knobFrames = $0 }
            .background(CodaDesignTokens.Colors.oled)
            .onAppear { store.setRootSize(geometry.size); store.testFixtureSeedIfRequested() }
            .onChange(of: geometry.size) { _, size in store.setRootSize(size) }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { store.pencilTouchCancelled(); store.clearRollTracking() }
            }
            .task {
                while !Task.isCancelled {
                    store.refreshTransportStatus()
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
    }
}

private struct EditorTopBar: View {
    @Bindable var store: CodaEditorStore
    @State private var tempoDragStart: Double?

    var body: some View {
        ZStack(alignment: .center) {
            HStack(spacing: CodaDesignTokens.Geometry.topBarControlGap) {
                leftCluster
                Spacer(minLength: 8)
                rightCluster
            }
            centerCluster
        }
        .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
        .padding(.horizontal, CodaDesignTokens.Geometry.topBarHorizontalPadding)
        .frame(height: CodaDesignTokens.Geometry.topBarHeight)
        .onPreferenceChange(SettingsFramesKey.self) { store.recordSettingsFrames($0, stage: "topBar.content") }
        .background { CodaAcrylic(store: store) }
        .onPreferenceChange(SettingsFramesKey.self) { store.recordSettingsFrames($0, stage: "topBar.acrylic") }
        .buttonStyle(.plain)
        // Give the container its own AX node so its identifier does not
        // propagate to (and replace the identifiers of) the controls inside.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.topBar")
    }

    @ViewBuilder
    private var leftCluster: some View {
        // Left cluster: Gallery, Unified Procreate Wrench, Key/Scale, Tempo, 4/4
        Button {
            store.projectHub.refreshIndex()
            withAnimation(.easeOut(duration: CodaDesignTokens.Motion.drawerDuration)) {
                store.projectHubOpen = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13, weight: .semibold))
                Text("Gallery")
                    .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
            }
            .padding(.horizontal, 8).frame(height: 32)
            .background(.white.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .accessibilityLabel("Project Gallery")
        .accessibilityIdentifier("top.gallery")

        Button {
            store.wrenchTab = .project
            store.presentSettings(.appSettings)
        } label: {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 32, height: 32)
                .background(store.popup == .appSettings ? .white.opacity(0.14) : .clear, in: Circle())
                .contentShape(Rectangle())
        }
        .modifier(SettingsAnchor(store: store, popup: .appSettings))
        .accessibilityLabel("Actions & Settings")
        .accessibilityIdentifier("top.appSettings")

        Rectangle().fill(CodaDesignTokens.Colors.primaryInk.opacity(0.08))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 2)

        Button { store.presentSettings(.keyScale) } label: {
            HStack(spacing: 6) {
                Text("\(CodaEditorStore.pitchName(for: store.key.tonic)) \(store.key.mode == .major ? "Maj" : "Min")")
                    .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                Text(store.key.mode == .major ? "MAJ" : "NAT")
                    .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
            }
            .padding(.horizontal, 9).frame(height: 32)
            .background(.white.opacity(0.06), in: Capsule())
        }
        .modifier(SettingsAnchor(store: store, popup: .keyScale))
        .accessibilityLabel("Key and scale")
        .accessibilityIdentifier("top.keyScale")
        .accessibilityValue("\(store.key.tonic)-\(store.key.mode == .major ? "major" : "natural minor")")

        HStack(spacing: 4) {
            Text("\(Int(store.tempo.rounded()))")
                .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
            Text("BPM").font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
        }
        .padding(.horizontal, 9).frame(height: 32)
        .background(.white.opacity(0.06), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { store.presentSettings(.tempo) }
        .gesture(DragGesture(minimumDistance: 4).onChanged { value in
            if tempoDragStart == nil { tempoDragStart = store.tempo }
            guard let tempoDragStart else { return }
            store.setTempo(tempoDragStart + Double((value.translation.width / 8).rounded()))
        }.onEnded { _ in tempoDragStart = nil })
        .modifier(SettingsAnchor(store: store, popup: .tempo))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tempo")
        .accessibilityValue("\(Int(store.tempo.rounded())) BPM")
        .accessibilityIdentifier("top.tempo")

        Text("4/4")
            .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
            .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
            .frame(height: 32).padding(.horizontal, 6)
            .accessibilityIdentifier("top.timeSignature")
    }

    @ViewBuilder
    private var rightCluster: some View {
        // Right cluster: Multi-layer pills + Layers popover + Synth Rack + AI Sidekick
        HStack(spacing: 3) {
            layerPill(.bass, title: "BASS")
            layerPill(.chords, title: "CHORD")
            layerPill(.melody, title: "MEL")
            Button { store.presentSettings(.layers) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 11, weight: .bold))
                    if !store.extraLayers.isEmpty {
                        Text("+\(store.extraLayers.count)")
                            .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                    }
                }
                .foregroundStyle(store.popup == .layers ? CodaDesignTokens.Colors.primaryInk : CodaDesignTokens.Colors.mutedInk)
                .padding(.horizontal, 7).frame(height: 28)
                .background(.white.opacity(store.popup == .layers ? 0.14 : 0.05), in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.innerPill))
                .contentShape(Rectangle())
            }
            .modifier(SettingsAnchor(store: store, popup: .layers))
            .accessibilityLabel("Layers")
            .accessibilityIdentifier("top.layers")
        }
        .padding(2)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.control))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("top.activeLayer")

        Button { store.toggleSynthRack() } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 12, weight: .bold))
                Text("SYNTH")
                    .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
            }
            .foregroundStyle(store.synthRackOpen ? Color.black : CodaDesignTokens.Colors.primaryInk)
            .padding(.horizontal, 9).frame(height: 32)
            .background(store.synthRackOpen ? CodaDesignTokens.Colors.chord : .white.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .accessibilityLabel("Toggle Synth & Plugin Rack")
        .accessibilityValue(store.synthRackOpen ? "open" : "closed")
        .accessibilityIdentifier("top.synthRack")

        Button { store.openDrawer() } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                Text("coda")
                    .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
            }
            .foregroundStyle(store.drawerOpen ? Color.black : CodaDesignTokens.Colors.sidekick)
            .padding(.horizontal, 9).frame(height: 30)
            .background(store.drawerOpen ? CodaDesignTokens.Colors.sidekick : CodaDesignTokens.Colors.sidekick.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .accessibilityLabel("Toggle AI Sidekick")
        .accessibilityIdentifier("top.sidekick")

        // Hidden AX readouts preserved for CI UI tests
        HStack(spacing: 0) {
            Text("Font registration")
                .font(CodaDesignTokens.Typography.font(size: 1))
                .frame(width: 1, height: 1).opacity(0.01)
                .accessibilityIdentifier("font.registration")
                .accessibilityValue(UIFont(name: CodaDesignTokens.Typography.lightFontPostScriptName, size: 12) == nil ? "font-missing" : "font-registered")
            Text(store.audioAvailable ? "available" : "inactive")
                .font(CodaDesignTokens.Typography.font(size: 1))
                .frame(width: 1, height: 1).opacity(0.01)
                .accessibilityIdentifier("editor.audioAvailability")
            Text("\(store.regionCount) chords")
                .font(CodaDesignTokens.Typography.font(size: 1))
                .frame(width: 1, height: 1).opacity(0.01)
                .accessibilityIdentifier("editor.regionCount")
            Text(store.canUndo ? "available" : "unavailable")
                .font(CodaDesignTokens.Typography.font(size: 1))
                .accessibilityIdentifier("editor.undoState")
                .accessibilityHidden(false)
                .frame(width: 1, height: 1)
            Text(store.canRedo ? "available" : "unavailable")
                .font(CodaDesignTokens.Typography.font(size: 1))
                .accessibilityIdentifier("editor.redoState")
                .accessibilityHidden(false)
                .frame(width: 1, height: 1)
            if store.uiDiagnosticsEnabled {
                Text("UI events")
                    .font(CodaDesignTokens.Typography.font(size: 1))
                    .frame(width: 1, height: 1).opacity(0.01)
                    .accessibilityIdentifier("editor.uiDiagnostics")
                    .accessibilityValue(store.uiDiagnosticReport)
            }
        }

        if store.patternEditing {
            PatternControlsView(store: store)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named("editor.root"))
                } action: {
                    store.recordPatternControlsFrame($0)
                }
                .onDisappear { store.recordPatternControlsFrame(.zero) }
        }
    }

    private var centerCluster: some View {
        // Mathematically DEAD-CENTER Play/Pause button flanked symmetrically by Loop & Layer Mutes
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Button { store.toggleLooping() } label: {
                    Image(systemName: "repeat").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(store.looping ? CodaDesignTokens.Colors.chord : CodaDesignTokens.Colors.mutedInk)
                        .frame(width: 32, height: 32)
                        .shadow(color: store.looping ? CodaDesignTokens.Colors.chord.opacity(0.24) : .clear, radius: 8)
                }
                .accessibilityIdentifier("top.loop")
                .accessibilityValue(store.looping ? "on" : "off")
            }
            .frame(width: 108, alignment: .trailing)

            Button { store.togglePlayback() } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(width: CodaDesignTokens.Geometry.playWidth, height: CodaDesignTokens.Geometry.playHeight)
                    .background(Color.white, in: Capsule())
                    .shadow(color: .white.opacity(0.18), radius: 12)
            }
            .accessibilityIdentifier("top.play")
            .accessibilityValue(store.isPlaying ? "playing" : "paused")

            HStack(spacing: 0) {
                layerMuteDot(.bass, identifier: "top.bassMute")
                Button { store.toggleChordMute() } label: {
                    Circle().fill(store.controls.muted == 0 ? CodaDesignTokens.Colors.chord : .clear)
                        .overlay(Circle().stroke(CodaDesignTokens.Colors.chord.opacity(0.55), lineWidth: 1.5))
                        .frame(width: 14, height: 14)
                        .frame(width: 28, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("top.chordMute")
                .accessibilityValue(store.controls.muted == 0 ? "sounding" : "muted")
                layerMuteDot(.melody, identifier: "top.melodyMute")
            }
            .frame(width: 108, alignment: .leading)
        }
    }

    private func layerPill(_ layer: MusicLayer, title: String) -> some View {
        let active = store.activeLayer == layer && store.activeExtraLayerID == nil
        let tint = CodaDesignTokens.Colors.layerTint(layer)
        return Button { store.setActiveLayer(layer) } label: {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title).font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                    .foregroundStyle(active ? tint : CodaDesignTokens.Colors.mutedInk)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(active ? tint.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.innerPill))
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("top.layer.\(layer.rawValue)")
        .accessibilityValue(active ? "active" : "")
    }

    private func layerMuteDot(_ layer: MusicLayer, identifier: String) -> some View {
        let sounding = !store.layerMuted(layer)
        let tint = CodaDesignTokens.Colors.layerTint(layer)
        return Button { store.toggleLayerMute(layer) } label: {
            Circle().fill(sounding ? tint : .clear)
                .overlay(Circle().stroke(tint.opacity(0.55), lineWidth: 1.5))
                .frame(width: 12, height: 12)
                .frame(width: 26, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier(identifier)
        .accessibilityValue(sounding ? "sounding" : "muted")
    }
}

private struct SettingsFramesKey: PreferenceKey {
    static let defaultValue: [EditorPopup: CGRect] = [:]
    static func reduce(value: inout [EditorPopup: CGRect], nextValue: () -> [EditorPopup: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

private struct PopupSizeKey: PreferenceKey {
    static let defaultValue = CGSize(width: 288, height: 300)
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct SettingsAnchor: ViewModifier {
    @Bindable var store: CodaEditorStore
    let popup: EditorPopup
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geometry in
                Color.clear.preference(key: SettingsFramesKey.self,
                    value: [popup: geometry.frame(in: .named("editor.root"))])
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("editor.root")) } action: {
                        store.recordSettingsFrames([popup: $0], stage: "producer.\(popup.rawValue)")
                    }
            }
        }
    }
}

/// Opaque base plus low-frequency content color: no sampled canvas, material,
/// refraction or transparency. Every menu uses this same compositing recipe.
struct CodaAcrylic: View {
    let store: CodaEditorStore
    var body: some View {
        let chord = store.regions.first { $0.id == store.selectedRegionID } ?? store.regions.first
        let tint = (chord?.chord.root ?? store.key.tonic) % 2 == 0
            ? CodaDesignTokens.Colors.chord : CodaDesignTokens.Colors.chordAlternate
        CodaDesignTokens.Colors.darkGlass
            .overlay(LinearGradient(colors: [tint.opacity(CodaDesignTokens.EditorSurface.acrylicTint),
                                              tint.opacity(CodaDesignTokens.EditorSurface.acrylicTint / 2)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(LinearGradient(colors: [.white.opacity(CodaDesignTokens.EditorSurface.acrylicHighlight), .clear],
                                    startPoint: .top, endPoint: .bottom))
            .allowsHitTesting(false)
    }
}

private struct AcrylicPanel: ViewModifier {
    let store: CodaEditorStore
    func body(content: Content) -> some View {
        content.background { CodaAcrylic(store: store) }
            .clipShape(RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card))
            .shadow(color: .black.opacity(0.35), radius: CodaDesignTokens.EditorSurface.elevationRadius,
                    y: CodaDesignTokens.EditorSurface.elevationOffset)
    }
}

private struct DrawerPullTab: View {
    @Bindable var store: CodaEditorStore

    var body: some View {
        Button { store.openDrawer() } label: {
            Capsule().fill(CodaDesignTokens.Colors.sidekick.opacity(0.8))
                .frame(width: CodaDesignTokens.EditorSurface.drawerHandleWidth,
                       height: CodaDesignTokens.EditorSurface.drawerHandleHeight)
                .frame(width: CodaDesignTokens.EditorSurface.drawerTabWidth,
                       height: CodaDesignTokens.EditorSurface.drawerTabHeight)
                .background { CodaAcrylic(store: store).clipShape(Capsule()) }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.drawerOpen ? "Close AI Sidekick drawer" : "Open AI Sidekick drawer")
        .accessibilityIdentifier("drawer.pullTab")
    }
}

private struct SynthRackPullTab: View {
    @Bindable var store: CodaEditorStore

    var body: some View {
        Button { store.toggleSynthRack() } label: {
            HStack(spacing: 6) {
                Capsule().fill(store.activeTrackColor.opacity(0.85))
                    .frame(width: 28, height: 3)
                Text(store.synthRackOpen ? "SYNTH RACK" : "SYNTH · FX")
                    .font(CodaDesignTokens.Typography.font(size: 9, weight: .bold))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                Image(systemName: store.synthRackOpen ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
            }
            .padding(.horizontal, 12)
            .frame(height: 20)
            .background { CodaAcrylic(store: store).clipShape(Capsule()) }
            .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.synthRackOpen ? "Close Synth Rack" : "Open Synth Rack")
        .accessibilityIdentifier("rack.pullTab")
    }
}

private struct TimelineStripView: View {
    @Bindable var store: CodaEditorStore
    @State private var startBraceX: CGFloat?
    @State private var endBraceX: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                CodaDesignTokens.Colors.darkGlass
                HStack(spacing: 0) {
                    HStack(spacing: 2) {
                        Text("1/16")
                            .accessibilityIdentifier("timeline.snap.division")
                        Text(store.gridSnap ? "SNAP" : "FREE")
                            .accessibilityIdentifier("timeline.snap.caption")
                    }
                        .font(CodaDesignTokens.Typography.font(size: CodaDesignTokens.Typography.noteAndLabelSize,
                                                               weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                        .fixedSize()
                        .frame(width: CodaDesignTokens.Geometry.timelineHeaderWidth, height: geometry.size.height)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("timeline.snap")
                        .contentShape(Rectangle())
                        .onTapGesture { store.gridSnap.toggle() }
                    GeometryReader { ruler in
                        ZStack(alignment: .topLeading) {
                            ForEach(store.visibleBars, id: \.self) { bar in
                                let x = CGFloat(store.viewport.x(forStep: Double(bar * MusicDefaults.stepsPerBar), in: Double(ruler.size.width)))
                                Text("\(bar + 1)")
                                    .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                                    .position(x: x + 5, y: 10)
                            }
                            let loopStart = CGFloat(store.viewport.x(forStep: Double(store.loop.start), in: Double(ruler.size.width)))
                            let loopEnd = CGFloat(store.viewport.x(forStep: Double(store.loop.end), in: Double(ruler.size.width)))
                            Rectangle().fill(CodaDesignTokens.Colors.chord.opacity(0.17))
                                .frame(width: max(0, loopEnd - loopStart), height: 2)
                                .position(x: loopStart + max(0, loopEnd - loopStart) / 2, y: geometry.size.height - 2)
                            Rectangle().fill(.clear)
                                .frame(width: 20, height: geometry.size.height)
                                .overlay(Rectangle().fill(CodaDesignTokens.Colors.chord).frame(width: 4))
                                .contentShape(Rectangle())
                                .position(x: loopStart, y: geometry.size.height / 2)
                                .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { value in
                                    if startBraceX == nil { startBraceX = loopStart + CodaDesignTokens.Geometry.timelineHeaderWidth }
                                    store.dragLoopHandle(edge: .start, toX: (startBraceX ?? loopStart) + value.translation.width)
                                }.onEnded { _ in startBraceX = nil })
                                .accessibilityIdentifier("timeline.loopStart")
                            Rectangle().fill(.clear)
                                .frame(width: 20, height: geometry.size.height)
                                .overlay(Rectangle().fill(CodaDesignTokens.Colors.chord).frame(width: 4))
                                .contentShape(Rectangle())
                                .position(x: loopEnd, y: geometry.size.height / 2)
                                .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { value in
                                    if endBraceX == nil { endBraceX = loopEnd + CodaDesignTokens.Geometry.timelineHeaderWidth }
                                    store.dragLoopHandle(edge: .end, toX: (endBraceX ?? loopEnd) + value.translation.width)
                                }.onEnded { _ in endBraceX = nil })
                                .accessibilityIdentifier("timeline.loopEnd")
                            Rectangle().fill(CodaDesignTokens.Colors.primaryInk.opacity(0.35))
                                .frame(width: 1, height: 24)
                                .position(x: CGFloat(store.viewport.x(forStep: Double(store.playheadStep), in: Double(ruler.size.width))), y: geometry.size.height / 2)
                                .accessibilityIdentifier("timeline.playhead")
                        }
                        .clipped()
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            store.scrub(toX: value.location.x + CodaDesignTokens.Geometry.timelineHeaderWidth)
                        })
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editor.timeline")
        }
        .frame(height: CodaDesignTokens.Geometry.timelineHeight)
    }
}

private struct ChordStripView: View {
    @Bindable var store: CodaEditorStore

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CHORDS")
                        .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    Text("Poly 12")
                        .font(CodaDesignTokens.Typography.font(size: 9))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInkAlternate)
                    Text("BAR")
                        .font(CodaDesignTokens.Typography.font(size: 9, weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInkAlternate)
                }
                .padding(.leading, 8)
                .frame(width: CodaDesignTokens.Geometry.pitchGutterWidth, alignment: .leading)
                .frame(height: geometry.size.height)
                GeometryReader { strip in
                    ZStack(alignment: .topLeading) {
                        CodaDesignTokens.Colors.oled
                        ForEach(store.visibleBars, id: \.self) { bar in
                            let start = bar * MusicDefaults.stepsPerBar
                            let occupied = store.displayedRegions.contains { $0.start < start + MusicDefaults.stepsPerBar && $0.end > start }
                            if !occupied {
                                RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card)
                                    .fill(CodaDesignTokens.Colors.darkGlass.opacity(0.40))
                                    .frame(width: max(8, CGFloat(store.viewport.stepWidth(in: Double(strip.size.width)) * Double(MusicDefaults.stepsPerBar)) - 6), height: 92)
                                    .overlay {
                                        VStack(spacing: 4) {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.system(size: 18, weight: .black))
                                            Text("BAR \(bar + 1)")
                                                .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                                        }
                                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk.opacity(0.4))
                                    }
                                    .offset(x: CGFloat(store.viewport.x(forStep: Double(start), in: Double(strip.size.width))), y: 6)
                                    .accessibilityElement()
                                    .accessibilityLabel("Empty chord bar \(bar + 1)")
                                    .accessibilityHint("Pencil adds at the bar start. Starts are bar constrained.")
                                    .accessibilityIdentifier("music.empty.\(bar + 1)")
                            }
                        }
                        ForEach(store.visibleRegions, id: \.id) { region in
                            let x = CGFloat(store.viewport.x(forStep: Double(region.start), in: Double(strip.size.width)))
                            let width = max(10, CGFloat(store.viewport.stepWidth(in: Double(strip.size.width)) * Double(region.length)))
                            ChordBlockView(store: store, region: region)
                                .frame(width: width, height: 92)
                                .offset(x: x, y: 6)
                        }
                        ForEach(store.sidekick.activeGhosts) { ghost in
                            let x = CGFloat(store.viewport.x(forStep: Double(ghost.startStep), in: Double(strip.size.width)))
                            let width = max(24, CGFloat(store.viewport.stepWidth(in: Double(strip.size.width)) * Double(ghost.lengthSteps)))
                            VStack(spacing: 4) {
                                Text(store.ghostChordName(ghost))
                                    .font(CodaDesignTokens.Typography.font(size: 16, weight: .bold))
                                    .foregroundStyle(CodaDesignTokens.Colors.sidekick)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Button { store.acceptGhost(ghost) } label: {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(CodaDesignTokens.Colors.sidekick)
                                    }
                                    Button { store.sidekick.dismissGhost(id: ghost.id) } label: {
                                        Image(systemName: "xmark.circle")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                                    }
                                }
                            }
                            .frame(width: width, height: 92)
                            .background(CodaDesignTokens.Colors.sidekick.opacity(0.10), in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card))
                            .overlay(
                                RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card)
                                    .stroke(CodaDesignTokens.Colors.sidekick.opacity(0.65),
                                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            )
                            .offset(x: x, y: 6)
                            .accessibilityIdentifier("music.ghost.\(ghost.id.uuidString)")
                        }
                        if let draft = store.resizeDraft {
                            let x = CGFloat(store.viewport.x(forStep: Double(draft.region.start), in: Double(strip.size.width)))
                            let width = max(8, CGFloat(store.viewport.stepWidth(in: Double(strip.size.width)) * Double(draft.end - draft.region.start)))
                            RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card)
                                .stroke(CodaDesignTokens.Colors.primaryInk.opacity(0.7), lineWidth: 1)
                                .frame(width: width, height: 92).offset(x: x, y: 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .clipped()
                    .background(CodaDesignTokens.Colors.oled)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("editor.chordStrip")
                }
            }
            .background(CodaDesignTokens.Colors.oled)
        }
        .frame(height: CodaDesignTokens.Geometry.chordStripHeight)
    }
}

private struct ChordBlockView: View {
    @Bindable var store: CodaEditorStore
    let region: ChordRegion

    var body: some View {
        let selected = store.selectedRegionID == region.id
        let playing = store.isPlaying && store.playheadStep >= region.start && store.playheadStep < region.end
        VStack(alignment: .center, spacing: 4) {
            Text(store.chordName(region) + (region.detectionUncertain ? " ?" : ""))
                .font(CodaDesignTokens.Typography.font(size: CodaDesignTokens.Typography.chordNameSize, weight: .bold))
                .lineLimit(1).minimumScaleFactor(0.72)
            Text(store.romanNumeral(region.chord))
                .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                .lineLimit(1)
            if store.detailsVisible || store.hoveredRegionID == region.id {
                let alterations = store.alterationText(region)
                Text("\(store.functionLabel(region.chord)) · \(store.voicingLabel(region))\n\(region.pitches.map(store.pitchName).joined(separator: " · "))\(alterations.isEmpty ? "" : "\n\(alterations)")")
                    .font(CodaDesignTokens.Typography.font(size: CodaDesignTokens.EditorSurface.chordDetailSize, weight: .bold))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    .lineLimit(CodaDesignTokens.EditorSurface.chordDetailLines)
                    .accessibilityIdentifier("music.detail.\(region.id)")
            }
        }
        .padding(CodaDesignTokens.Geometry.chordInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
        .clipped()
        .background(CodaDesignTokens.Colors.chord.opacity(playing ? 0.28 : 0.14),
                    in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card))
        .overlay(alignment: .trailing) {
            if store.hoveredRegionID == region.id {
                Capsule().fill(CodaDesignTokens.Colors.primaryInk.opacity(0.45))
                    .frame(width: 2, height: 24).padding(.trailing, 4)
            }
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card)
                    .stroke(CodaDesignTokens.Colors.chord.opacity(0.45), lineWidth: 1.5)
                    .padding(1.5)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(store.chordName(region)), \(store.romanNumeral(region.chord)), bar \(region.start / MusicDefaults.stepsPerBar + 1)")
        .accessibilityIdentifier("music.chord.\(region.id)")
        .accessibilityValue(selected ? "selected" : "")
        .accessibilityHint("Pencil auditions; right edge resizes on the step grid. Chord starts are fixed.")
    }
}

private struct PianoRollView: View {
    @Bindable var store: CodaEditorStore

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        pitchGutter(height: geometry.size.height)
                        Button { store.scaleLockEnabled.toggle() } label: {
                            HStack(spacing: 3) {
                                Image(systemName: store.scaleLockEnabled ? "lock.fill" : "lock.open")
                                    .font(.system(size: 9, weight: .bold))
                                Text("SCL")
                                    .font(CodaDesignTokens.Typography.font(size: 8, weight: .black))
                            }
                            .foregroundStyle(store.scaleLockEnabled ? Color.black : CodaDesignTokens.Colors.mutedInk)
                            .padding(.horizontal, 5).padding(.vertical, 3)
                            .background(store.scaleLockEnabled ? CodaDesignTokens.Colors.chord : Color.black.opacity(0.65), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                        .accessibilityLabel(store.scaleLockEnabled ? "Scale Lock On" : "Scale Lock Off")
                        .accessibilityIdentifier("roll.scaleLock")
                    }
                    ZStack(alignment: .topLeading) {
                        Canvas { context, size in
                            drawGrid(in: &context, size: size)
                            var notes = context
                            notes.opacity = store.patternEditing ? 0.25 : 1
                            drawNotes(in: &notes, size: size)
                            drawPlayhead(in: &context, size: size)
                        }
                        .background(CodaDesignTokens.Colors.oled)
                        .contentShape(Rectangle())
                        .onTapGesture { if store.drawerOpen { store.openDrawer(false) } }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Chord piano roll, Pencil \(store.rollTool.rawValue)")
                        .accessibilityIdentifier("editor.pianoRoll")
                    }
                }
                .background(CodaDesignTokens.Colors.oled)
            }
            .background(CodaDesignTokens.Colors.oled)
            .clipped()

            // Collapsible FL-style Velocity Lane pull-bar + 64pt stem editor
            VelocityLaneView(store: store)
        }
        .background(CodaDesignTokens.Colors.oled)
    }

    private func pitchGutter(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            CodaDesignTokens.Colors.coalGutter
            ForEach(store.viewport.visiblePitches(in: Double(height)), id: \.self) { midi in
                let accidental = [1, 3, 6, 8, 10].contains(midi % 12)
                let octave = midi.isMultiple(of: 12)
                let row = CGFloat(store.viewport.semitoneHeight)
                let y = CGFloat(store.viewport.y(forMIDI: midi))
                Rectangle()
                    .fill(CodaDesignTokens.Colors.primaryInk.opacity(accidental
                        ? CodaDesignTokens.EditorSurface.keyboardAccidentalOpacity
                        : CodaDesignTokens.EditorSurface.keyboardNaturalOpacity))
                    .frame(width: accidental ? CodaDesignTokens.EditorSurface.keyboardAccidentalWidth
                                            : CodaDesignTokens.Geometry.pitchGutterWidth,
                           height: row - CodaDesignTokens.Geometry.noteMicroInset)
                    .offset(y: y)
                Text(store.pitchName(midi))
                    .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                    .foregroundStyle(CodaDesignTokens.Colors.primaryInk.opacity(octave ? 0.9 : 0.65))
                    .frame(width: CodaDesignTokens.Geometry.pitchGutterWidth - CodaDesignTokens.EditorSurface.keyboardLabelInset,
                           height: row, alignment: .trailing)
                    .offset(y: y)
                    .accessibilityIdentifier("roll.pitch.\(midi)")
            }
        }
        .frame(width: CodaDesignTokens.Geometry.pitchGutterWidth, height: height)
        .clipped()
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        let row = CGFloat(store.viewport.semitoneHeight)
        for midi in 0...127 {
            let y = CGFloat(store.viewport.y(forMIDI: midi))
            guard y + row >= 0, y < size.height else { continue }
            let inScale = store.scaleContains(midi)
            let color: Color = if store.scaleLockEnabled && !inScale {
                CodaDesignTokens.Colors.oled
            } else if store.scaleHighlightsVisible && inScale {
                CodaDesignTokens.Colors.coalScale
            } else {
                CodaDesignTokens.Colors.oled
            }
            context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: row)), with: .color(color))
            if store.scaleLockEnabled && !inScale {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: row)), with: .color(.black.opacity(0.42)))
            }
            var horizontal = Path(); horizontal.move(to: CGPoint(x: 0, y: y)); horizontal.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(horizontal, with: .color(CodaDesignTokens.Colors.primaryInk.opacity(0.025)), lineWidth: 0.5)
        }
        for step in store.viewport.visibleSteps(in: Double(size.width)) {
            let x = CGFloat(store.viewport.x(forStep: Double(step), in: Double(size.width)))
            guard x >= 0, x <= size.width else { continue }
            let isBar = step.isMultiple(of: MusicDefaults.stepsPerBar)
            let isBeat = step.isMultiple(of: MusicDefaults.stepsPerBeat)
            guard isBar || isBeat else { continue }
            var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
            let opacity = isBar ? 0.11 : 0.05
            context.stroke(line, with: .color(CodaDesignTokens.Colors.primaryInk.opacity(opacity)), lineWidth: isBar ? 1 : 0.5)
        }
    }

    private func drawNotes(in context: inout GraphicsContext, size: CGSize) {
        let chordOpacity = store.activeLayer == .chords ? 0.78 : store.ghostLayersOpacity
        for region in store.visibleRegions {
            let liveChord: Chord? = store.noteLabelsVisible
                ? (store.session.flatMap { ChordDetector.detect(notes: region.notes, previous: region.chord, vocabulary: $0.vocabulary) } ?? region.chord)
                : nil
            for value in region.notes {
                let rootFrame = store.noteFrame(value, in: region)
                let rect = rootFrame.offsetBy(dx: -CodaDesignTokens.Geometry.pitchGutterWidth, dy: -store.rollTop)
                    .insetBy(dx: 0.75, dy: CodaDesignTokens.Geometry.noteMicroInset)
                guard rect.maxY > 0, rect.minY < size.height, rect.maxX > 0, rect.minX < size.width else { continue }
                let selected = store.activeLayer == .chords && store.selectedNotes.contains(RollNoteReference(regionID: region.id, noteID: value.id))
                let path = Path(roundedRect: rect, cornerRadius: 4)
                context.fill(path, with: .color(CodaDesignTokens.Colors.chord.opacity(selected ? 1 : chordOpacity)))
                if selected { context.stroke(path, with: .color(.white.opacity(0.65)), lineWidth: 1.2) }
                if value.slide {
                    var slide = Path(); slide.move(to: CGPoint(x: rect.minX + 4, y: rect.maxY - 3))
                    slide.addLine(to: CGPoint(x: min(rect.maxX - 3, rect.minX + 14), y: rect.minY + 3))
                    context.stroke(slide, with: .color(.white.opacity(0.6)), lineWidth: 1)
                }
                if store.noteLabelsVisible, store.activeLayer == .chords, rect.width > 35 {
                    var labels = context
                    labels.clip(to: path)
                    labels.draw(Text(store.pitchName(value.pitch)).font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.black.opacity(0.8)), at: CGPoint(x: rect.minX + 5, y: rect.midY), anchor: .leading)
                    if rect.width > 86, let liveChord, let vocabulary = store.session?.vocabulary {
                        let function = ChordDetector.toneLabel(pitch: value.pitch, chord: liveChord, vocabulary: vocabulary)
                        labels.draw(Text(function).font(.system(size: 10, weight: .medium)).foregroundColor(.black.opacity(0.7)),
                            at: CGPoint(x: rect.maxX - 5, y: rect.midY), anchor: .trailing)
                    }
                }
            }
        }
        // Bass layer notes (full opacity when active, ghost opacity when inactive)
        let bassOpacity = store.activeLayer == .bass ? 0.85 : store.ghostLayersOpacity
        for note in store.displayedBassNotes {
            let rect = store.bassNoteFrame(note)
                .offsetBy(dx: -CodaDesignTokens.Geometry.pitchGutterWidth, dy: -store.rollTop)
                .insetBy(dx: 0.75, dy: CodaDesignTokens.Geometry.noteMicroInset)
            guard rect.maxY > 0, rect.minY < size.height, rect.maxX > 0, rect.minX < size.width else { continue }
            let selected = store.activeLayer == .bass && store.selectedLayerNoteIDs.contains(note.id)
            let path = Path(roundedRect: rect, cornerRadius: 4)
            context.fill(path, with: .color(CodaDesignTokens.Colors.bass.opacity(selected ? 1 : bassOpacity)))
            if selected { context.stroke(path, with: .color(.white.opacity(0.7)), lineWidth: 1.2) }
        }
        // Melody layer notes (full opacity when active, ghost opacity when inactive)
        let melodyOpacity = store.activeLayer == .melody ? 0.88 : store.ghostLayersOpacity
        for note in store.displayedMelodyNotes {
            let rect = store.melodyNoteFrame(note)
                .offsetBy(dx: -CodaDesignTokens.Geometry.pitchGutterWidth, dy: -store.rollTop)
                .insetBy(dx: 0.75, dy: CodaDesignTokens.Geometry.noteMicroInset)
            guard rect.maxY > 0, rect.minY < size.height, rect.maxX > 0, rect.minX < size.width else { continue }
            let selected = store.activeLayer == .melody && store.selectedLayerNoteIDs.contains(note.id)
            let path = Path(roundedRect: rect, cornerRadius: 4)
            context.fill(path, with: .color(CodaDesignTokens.Colors.melody.opacity(selected ? 1 : melodyOpacity)))
            if selected { context.stroke(path, with: .color(.white.opacity(0.7)), lineWidth: 1.2) }
        }
        if let marquee = store.rollMarquee {
            let rect = marquee.offsetBy(dx: -CodaDesignTokens.Geometry.pitchGutterWidth, dy: -store.rollTop)
            context.fill(Path(rect), with: .color(.white.opacity(0.06)))
            context.stroke(Path(rect), with: .color(.white.opacity(0.4)), lineWidth: 1)
        }
        if let point = store.razorPoint {
            let x = point.x - CodaDesignTokens.Geometry.pitchGutterWidth
            var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(.white.opacity(0.7)), lineWidth: 1)
        }
        context.draw(Text(store.rollTool == .drawErase ? "Draw / Erase" : store.rollTool == .razor ? "Razor" : "Selection")
            .font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.35)), at: CGPoint(x: 12, y: 14), anchor: .leading)
    }

    private func drawPlayhead(in context: inout GraphicsContext, size: CGSize) {
        let x = CGFloat(store.viewport.x(forStep: Double(store.playheadStep), in: Double(size.width)))
        guard x >= 0, x <= size.width else { return }
        var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(CodaDesignTokens.Colors.primaryInk.opacity(0.35)), lineWidth: 1)
    }
}

/// Collapsible FL-style Velocity Lane (~64pt tall when expanded) at the bottom of the piano roll.
private struct VelocityLaneView: View {
    @Bindable var store: CodaEditorStore

    private struct VelocityStem: Identifiable {
        let id: String
        let step: Double
        let velocity: Int
    }

    private var stems: [VelocityStem] {
        if let extraID = store.activeExtraLayerID,
           let extra = store.extraLayers.first(where: { $0.id == extraID }) {
            return extra.notes.map { note in
                VelocityStem(id: note.id, step: Double(note.startTick) / Double(MusicDefaults.ticksPerStep), velocity: note.velocity)
            }
        }
        switch store.activeLayer {
        case .chords:
            return store.visibleRegions.flatMap { region in
                region.notes.map { note in
                    let step = Double(region.start) + Double(note.startTick) / Double(MusicDefaults.ticksPerStep)
                    return VelocityStem(id: "\(region.id)-\(note.id)", step: step, velocity: note.velocity)
                }
            }
        case .bass:
            return store.displayedBassNotes.map { note in
                VelocityStem(id: note.id, step: Double(note.startTick) / Double(MusicDefaults.ticksPerStep), velocity: note.velocity)
            }
        case .melody:
            return store.displayedMelodyNotes.map { note in
                VelocityStem(id: note.id, step: Double(note.startTick) / Double(MusicDefaults.ticksPerStep), velocity: note.velocity)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Slim VEL pull-bar
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { store.velocityLaneVisible.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text("VEL")
                            .font(CodaDesignTokens.Typography.font(size: 9, weight: .black))
                        Image(systemName: store.velocityLaneVisible ? "chevron.down" : "chevron.up")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(store.velocityLaneVisible ? store.activeTrackColor : CodaDesignTokens.Colors.mutedInk)
                    .frame(width: CodaDesignTokens.Geometry.pitchGutterWidth, height: 18)
                    .background(CodaDesignTokens.Colors.coalGutter)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.velocityLaneVisible ? "Hide velocity lane" : "Show velocity lane")
                .accessibilityIdentifier("roll.velocityToggle")

                Rectangle()
                    .fill(CodaDesignTokens.Colors.primaryInk.opacity(0.08))
                    .frame(height: 1)
            }
            .frame(height: 18)
            .background(CodaDesignTokens.Colors.oled)

            if store.velocityLaneVisible {
                HStack(spacing: 0) {
                    VStack(spacing: 2) {
                        Text("127").font(CodaDesignTokens.Typography.font(size: 8, weight: .bold))
                        Spacer()
                        Text("VEL").font(CodaDesignTokens.Typography.font(size: 9, weight: .black))
                            .foregroundStyle(store.activeTrackColor)
                        Spacer()
                        Text("1").font(CodaDesignTokens.Typography.font(size: 8, weight: .bold))
                    }
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    .padding(.vertical, 4)
                    .frame(width: CodaDesignTokens.Geometry.pitchGutterWidth, height: 64)
                    .background(CodaDesignTokens.Colors.coalGutter)

                    GeometryReader { lane in
                        let tint = store.activeTrackColor
                        Canvas { context, size in
                            // Midline reference (velocity ~64)
                            var mid = Path()
                            mid.move(to: CGPoint(x: 0, y: size.height * 0.5))
                            mid.addLine(to: CGPoint(x: size.width, y: size.height * 0.5))
                            context.stroke(mid, with: .color(.white.opacity(0.06)), lineWidth: 0.5)

                            for stem in stems {
                                let x = CGFloat(store.viewport.x(forStep: stem.step, in: Double(size.width)))
                                guard x >= 0, x <= size.width else { continue }
                                let norm = CGFloat(min(127, max(1, stem.velocity))) / 127.0
                                let topY = size.height - max(4, norm * (size.height - 8))
                                var line = Path()
                                line.move(to: CGPoint(x: x + 3, y: size.height))
                                line.addLine(to: CGPoint(x: x + 3, y: topY))
                                context.stroke(line, with: .color(tint.opacity(0.85)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                let cap = CGRect(x: x, y: topY - 3, width: 6, height: 6)
                                context.fill(Path(ellipseIn: cap), with: .color(tint))
                            }
                        }
                        .background(CodaDesignTokens.Colors.oled)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            guard let step = store.viewport.step(atX: Double(value.location.x), in: Double(lane.size.width)) else { return }
                            let fraction = 1.0 - Double(min(lane.size.height, max(0, value.location.y)) / max(1, lane.size.height))
                            let velocity = max(1, min(127, Int((fraction * 127.0).rounded())))
                            store.setVelocity(velocity, atStep: step)
                        })
                        .accessibilityIdentifier("roll.velocityLane")
                    }
                    .frame(height: 64)
                }
            }
        }
    }
}

private struct SynthDrawer: View {
    @Bindable var store: CodaEditorStore

    var body: some View {
        // Right drawer is 100% AI Sidekick ONLY. Synth & plugins live in BottomSynthRackView.
        SidekickDrawerView(store: store)
            .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
            .background { CodaAcrylic(store: store) }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: CodaDesignTokens.Radii.card,
                                              bottomLeadingRadius: CodaDesignTokens.Radii.card))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editor.synthDrawer")
            .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.width > 60 && abs(value.translation.width) > abs(value.translation.height) {
                    store.openDrawer(false)
                }
            })
            .buttonStyle(.plain)
    }
}

private struct KnobControl: View {
    @Bindable var store: CodaEditorStore
    let knob: EditorKnob
    let diameter: CGFloat
    @State private var dragStart: Double?

    private var value: Double { store.value(for: knob) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().trim(from: 0.125, to: 0.875).stroke(.white.opacity(0.10), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Circle().trim(from: 0.125, to: 0.125 + 0.75 * value)
                    .stroke(CodaDesignTokens.Colors.chord, style: StrokeStyle(lineWidth: 3, lineCap: .round))
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
                    .font(CodaDesignTokens.Typography.font(size: CodaDesignTokens.Typography.chipAndReadoutSize,
                                                           weight: .bold))
                    .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
                    .fixedSize()
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.white.opacity(0.08), in: Capsule())
                    .accessibilityIdentifier("drawer.knob.readout.\(knob.rawValue)")
            }
            Text("Default \(Int((store.presetDefault(for: knob) * 100).rounded()))")
                .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                .foregroundStyle(CodaDesignTokens.Colors.mutedInkAlternate)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(knob.title)
        .accessibilityValue("\(Int((value * 100).rounded())) percent; preset default \(Int((store.presetDefault(for: knob) * 100).rounded())) percent")
        .accessibilityIdentifier("drawer.knob.\(knob.rawValue)")
    }
}

private struct EditorSettingsPopover: View {
    @Bindable var store: CodaEditorStore
    let popup: EditorPopup

    var body: some View {
        // Keep a concrete container for the popup identifier. Group is
        // structurally flattened and does not reliably expose its own AX node.
        ZStack(alignment: .topLeading) {
            switch popup {
            case .appSettings, .projectSettings:
                unifiedWrenchSettings
            case .layers:
                layersPopover
            case .keyScale:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Key & Scale").font(CodaDesignTokens.Typography.font(size: 15, weight: .bold))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                        ForEach(0..<12, id: \.self) { tonic in
                            Button { store.setKey(tonic: tonic, mode: store.key.mode) } label: {
                                Text(CodaEditorStore.pitchName(for: tonic))
                                    .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                                    .frame(maxWidth: .infinity).frame(height: 32)
                                    .background(.white.opacity(store.key.tonic == tonic ? 0.14 : 0.04), in: Capsule())
                            }
                            .accessibilityIdentifier("settings.key.\(tonic)")
                        }
                    }
                    HStack {
                        ForEach([0, 1], id: \.self) { index in
                            let mode: KeyMode = index == 0 ? .major : .naturalMinor
                            Button(mode == .major ? "Major" : "Natural Minor") {
                                store.setKey(tonic: store.key.tonic, mode: mode)
                            }
                            .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                            .padding(8)
                            .background(.white.opacity(store.key.mode == mode ? 0.14 : 0.04), in: Capsule())
                            .accessibilityIdentifier(mode == .major ? "settings.scale.major" : "settings.scale.minor")
                        }
                    }
                    Text("Key changes suggestions and scale shading. Existing chords stay as written.")
                        .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                }
            case .tempo:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Tempo").font(CodaDesignTokens.Typography.font(size: 15, weight: .bold))
                    HStack {
                        TextField("BPM", text: $store.tempoDraft)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(CodaDesignTokens.Colors.coalGutter,
                                        in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.control))
                            .accessibilityIdentifier("settings.tempoField")
                            .onSubmit { store.commitTempoDraft() }
                        Text("BPM").font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                    }
                    Button { store.commitTempoDraft(); store.popup = nil } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: CodaDesignTokens.EditorSurface.toolIconSize, weight: .black))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Apply tempo")
                    .accessibilityIdentifier("settings.applyTempo")
                }
            }
        }
        .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
        .buttonStyle(.plain)
        .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
        .padding(CodaDesignTokens.EditorSurface.popupPadding)
        .frame(width: (popup == .appSettings || popup == .projectSettings) ? 436 : (popup == .layers ? 320 : CodaDesignTokens.EditorSurface.popupWidth))
        .background { CodaAcrylic(store: store) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.popup.\(popup.rawValue)")
    }

    // MARK: - Unified Procreate Wrench Settings Dropdown (Default Tab = Project)
    private var unifiedWrenchSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(WrenchSettingsTab.allCases) { tab in
                    let active = store.wrenchTab == tab
                    Button { store.wrenchTab = tab } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 13, weight: .semibold))
                            Text(tab.title)
                                .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                                .lineLimit(1).minimumScaleFactor(0.75)
                        }
                        .foregroundStyle(active ? CodaDesignTokens.Colors.chord : CodaDesignTokens.Colors.mutedInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(active ? CodaDesignTokens.Colors.chord.opacity(0.14) : .white.opacity(0.03),
                                    in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.control))
                    }
                    .accessibilityIdentifier("wrench.tab.\(tab.rawValue)")
                }
            }

            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch store.wrenchTab {
                    case .project: projectTabContent
                    case .importExport: importExportTabContent
                    case .canvas: canvasTabContent
                    case .gestures: gesturesTabContent
                    case .prefs: prefsTabContent
                    }
                }
            }
            .frame(maxHeight: 380)
            .scrollIndicators(.hidden)
        }
    }

    private var projectTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Sketch Name", text: $store.currentProjectName)
                    .textFieldStyle(.plain)
                    .font(CodaDesignTokens.Typography.font(size: 13, weight: .bold))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(CodaDesignTokens.Colors.coalGutter,
                                in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.control))
                Button { store.saveCurrentProject() } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                        .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(CodaDesignTokens.Colors.chord.opacity(0.18), in: Capsule())
                        .foregroundStyle(CodaDesignTokens.Colors.chord)
                }
                .accessibilityIdentifier("wrench.project.save")
            }

            HStack(spacing: 8) {
                wrenchActionButton("Gallery / Hub", symbol: "square.grid.2x2") {
                    store.popup = nil
                    store.projectHub.refreshIndex()
                    store.projectHubOpen = true
                }
                wrenchActionButton(store.abSnapshotActive ? "A/B (B)" : "A/B (A)", symbol: "arrow.left.arrow.right") {
                    store.toggleABSnapshot()
                }
                wrenchActionButton("Capture A", symbol: "camera.aperture") {
                    store.captureABSnapshot()
                }
            }

            HStack(spacing: 8) {
                wrenchActionButton("Transpose -1", symbol: "minus.circle") { store.transposeAll(by: -1) }
                wrenchActionButton("Transpose +1", symbol: "plus.circle") { store.transposeAll(by: 1) }
                wrenchActionButton(store.key.mode == .major ? "Rel. Minor" : "Rel. Major", symbol: "music.note") {
                    store.convertToRelativeKey()
                }
            }

            HStack(spacing: 8) {
                wrenchActionButton("+ Bar Duplicate", symbol: "plus.square.on.square") { store.duplicateLastBar() }
                wrenchActionButton("Clear \(store.activeLayerDisplayName)", symbol: "trash", destructive: true) {
                    store.clearActiveLayer()
                }
            }

            HStack {
                Text("Loop length").font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                Spacer()
                Stepper("\(store.loop.length / 16) bars", value: Binding(
                    get: { store.loop.length / 16 }, set: { store.setLoopBars($0) }),
                    in: 1...(Int.max / MusicDefaults.ticksPerStep / MusicDefaults.stepsPerBar))
                    .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                    .accessibilityIdentifier("settings.loopLength")
            }
        }
    }

    private var importExportTabContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            wrenchActionButton("Import SoundFont (.sf2 / .dls)", symbol: "waveform.badge.plus") {
                store.popup = nil
                store.synthRackTab = .importSoundFont
                store.toggleSynthRack(true)
            }
            wrenchActionButton("Scan AUv3 Plugins", symbol: "puzzlepiece.extension") {
                store.popup = nil
                store.synthRackTab = .auv3Plugins
                store.pluginHost.scanAvailablePlugins()
                store.toggleSynthRack(true)
            }
            wrenchActionButton("Import Project JSON", symbol: "square.and.arrow.down") {
                store.popup = nil
                store.projectHubOpen = true
            }
            HStack(spacing: 8) {
                wrenchActionButton("Export MIDI (.mid)", symbol: "music.note.list") {
                    store.exportMIDIForProject()
                }
                wrenchActionButton("Export JSON", symbol: "doc.text") {
                    store.exportJSONForProject()
                }
            }
        }
    }

    private var canvasTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Grid Snap (1/16)", isOn: $store.gridSnap)
                .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                .accessibilityIdentifier("settings.gridSnap")
            Toggle("Note labels", isOn: $store.noteLabelsVisible)
                .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                .accessibilityIdentifier("settings.noteLabels")
            Toggle("Chord details", isOn: $store.detailsVisible)
                .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                .accessibilityIdentifier("settings.chordDetails")
            Toggle("Scale highlights", isOn: $store.scaleHighlightsVisible)
                .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                .accessibilityIdentifier("settings.scaleHighlights")
            Toggle("Scale Lock (snap pitches)", isOn: $store.scaleLockEnabled)
                .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                .accessibilityIdentifier("settings.scaleLock")
            Toggle("Velocity lane", isOn: $store.velocityLaneVisible)
                .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                .accessibilityIdentifier("settings.velocityLane")
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Ghost Layers Opacity")
                        .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                    Spacer()
                    Text("\(Int((store.ghostLayersOpacity * 100).rounded()))%")
                        .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                }
                Slider(value: $store.ghostLayersOpacity, in: 0.05...0.75)
                    .tint(CodaDesignTokens.Colors.chord)
            }
            wrenchActionButton("Reset Canvas Zoom", symbol: "arrow.up.left.and.arrow.down.right") {
                store.resetZoom()
            }
        }
    }

    private var gesturesTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("APPLE PENCIL PRO DOUBLE TAP")
                .font(CodaDesignTokens.Typography.font(size: 10, weight: .black))
                .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(PencilDoubleTapAction.allCases) { action in
                    let selected = store.gestureSettings.pencilDoubleTap == action
                    Button { store.gestureSettings.pencilDoubleTap = action } label: {
                        HStack(spacing: 5) {
                            Image(systemName: action.symbol).font(.system(size: 11, weight: .bold))
                            Text(action.title).lineLimit(1).minimumScaleFactor(0.75)
                        }
                        .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                        .foregroundStyle(selected ? CodaDesignTokens.Colors.chord : CodaDesignTokens.Colors.primaryInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(selected ? CodaDesignTokens.Colors.chord.opacity(0.16) : .white.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.innerPill))
                    }
                    .accessibilityIdentifier("gestures.doubleTap.\(action.rawValue)")
                }
            }

            Text("APPLE PENCIL SQUEEZE")
                .font(CodaDesignTokens.Typography.font(size: 10, weight: .black))
                .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
            HStack(spacing: 4) {
                ForEach(PencilSqueezeAction.allCases) { action in
                    let selected = store.gestureSettings.pencilSqueeze == action
                    Button { store.gestureSettings.pencilSqueeze = action } label: {
                        Text(action.title)
                            .font(CodaDesignTokens.Typography.font(size: 9, weight: .bold))
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(selected ? CodaDesignTokens.Colors.chord : CodaDesignTokens.Colors.mutedInk)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6).padding(.horizontal, 4)
                            .background(selected ? CodaDesignTokens.Colors.chord.opacity(0.16) : .white.opacity(0.05),
                                        in: Capsule())
                    }
                }
            }

            Text("BARREL ROLL")
                .font(CodaDesignTokens.Typography.font(size: 10, weight: .black))
                .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
            HStack(spacing: 4) {
                ForEach(BarrelRollMode.allCases) { mode in
                    let selected = store.gestureSettings.barrelRoll == mode
                    Button { store.gestureSettings.barrelRoll = mode } label: {
                        Text(mode.title)
                            .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                            .lineLimit(1).minimumScaleFactor(0.75)
                            .foregroundStyle(selected ? CodaDesignTokens.Colors.chord : CodaDesignTokens.Colors.mutedInk)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6).padding(.horizontal, 6)
                            .background(selected ? CodaDesignTokens.Colors.chord.opacity(0.16) : .white.opacity(0.05),
                                        in: Capsule())
                    }
                }
            }

            Toggle("2-Finger Tap Undo", isOn: Bindable(store.gestureSettings).twoFingerTapUndo)
                .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
            Toggle("3-Finger Tap Redo", isOn: Bindable(store.gestureSettings).threeFingerTapRedo)
                .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
            Toggle("Haptic Detents", isOn: Bindable(store.gestureSettings).hapticsEnabled)
                .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Hold Menu Delay")
                        .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                    Spacer()
                    Text("\(Int(store.gestureSettings.holdMenuDelayMs.rounded())) ms")
                        .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                }
                Slider(value: Bindable(store.gestureSettings).holdMenuDelayMs, in: 180...600, step: 20)
                    .tint(CodaDesignTokens.Colors.chord)
            }

            wrenchActionButton("Reset Gesture Defaults", symbol: "arrow.counterclockwise") {
                store.gestureSettings.resetDefaults()
            }
        }
    }

    private var prefsTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AUDIO ENGINE")
                .font(CodaDesignTokens.Typography.font(size: 10, weight: .black))
                .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
            Text(store.audioAvailable ? "AVAudioEngine · 48 kHz · Active" : "Audio output starts on Play or Pencil audition")
                .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                .accessibilityIdentifier("settings.audioOutput")
            Text("Grid · 16 steps per bar · Off-bar chord placement enabled")
                .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                .accessibilityIdentifier("settings.grid")

            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)

            Text("ON-DEVICE AI SIDEKICK (QWEN3-4B-4BIT)")
                .font(CodaDesignTokens.Typography.font(size: 10, weight: .black))
                .foregroundStyle(CodaDesignTokens.Colors.sidekick)
            HStack {
                Text(sidekickModelStatusText)
                    .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                    .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
                Spacer()
                if case .ready = store.sidekick.modelState {
                    EmptyView()
                } else {
                    Button { store.sidekick.startModelDownload() } label: {
                        Text("Download 2.3 GB")
                            .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(CodaDesignTokens.Colors.sidekick.opacity(0.20), in: Capsule())
                            .foregroundStyle(CodaDesignTokens.Colors.sidekick)
                    }
                }
            }

            if let error = store.audioError {
                Text(error).font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                    .foregroundStyle(CodaDesignTokens.Colors.danger)
            }
        }
    }

    private var sidekickModelStatusText: String {
        switch store.sidekick.modelState {
        case .notDownloaded: return "Not downloaded (2.3 GB)"
        case .downloading(let progress): return "Downloading \(Int(progress * 100))%"
        case .ready, .loaded: return "Ready on device"
        case .unloadedIdle: return "Cached on device (idle)"
        case .offlineUnavailable(let message): return "Offline: \(message)"
        case .memoryConstrained(let message): return "Low RAM: \(message)"
        }
    }

    // MARK: - Procreate-style Multi-Layer Popover
    private var layersPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Layers").font(CodaDesignTokens.Typography.font(size: 15, weight: .bold))
                Spacer()
                Text("\(3 + store.extraLayers.count) tracks")
                    .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
            }

            VStack(spacing: 6) {
                ForEach([MusicLayer.bass, .chords, .melody], id: \.self) { layer in
                    let active = store.activeLayer == layer && store.activeExtraLayerID == nil
                    let tint = CodaDesignTokens.Colors.layerTint(layer)
                    HStack(spacing: 8) {
                        Circle().fill(tint).frame(width: 8, height: 8)
                        Text(layer.rawValue.capitalized)
                            .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                            .foregroundStyle(active ? tint : CodaDesignTokens.Colors.primaryInk)
                        Spacer()
                        Button { store.toggleLayerMute(layer) } label: {
                            Image(systemName: store.layerMuted(layer) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(store.layerMuted(layer) ? CodaDesignTokens.Colors.mutedInk : tint)
                                .frame(width: 28, height: 28)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(active ? tint.opacity(0.14) : .white.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.control))
                    .contentShape(Rectangle())
                    .onTapGesture { store.setActiveLayer(layer) }
                }

                ForEach(store.extraLayers) { extra in
                    let active = store.activeExtraLayerID == extra.id
                    let tint = CodaDesignTokens.Colors.layerTint(extra.kind)
                    HStack(spacing: 8) {
                        Circle().fill(tint).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(extra.name)
                                .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                                .foregroundStyle(active ? tint : CodaDesignTokens.Colors.primaryInk)
                            if let plugin = extra.pluginID {
                                Text(plugin)
                                    .font(CodaDesignTokens.Typography.font(size: 9, weight: .medium))
                                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                            }
                        }
                        Spacer()
                        Button { store.setExtraLayerMuted(!extra.muted, for: extra.id) } label: {
                            Image(systemName: extra.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(extra.muted ? CodaDesignTokens.Colors.mutedInk : tint)
                                .frame(width: 24, height: 24)
                        }
                        Button { store.removeExtraLayer(id: extra.id) } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(CodaDesignTokens.Colors.danger)
                                .frame(width: 24, height: 24)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(active ? tint.opacity(0.14) : .white.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.control))
                    .contentShape(Rectangle())
                    .onTapGesture { store.selectExtraLayer(id: extra.id) }
                }
            }

            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)

            HStack(spacing: 6) {
                addLayerButton("+ Chord", kind: .chords)
                addLayerButton("+ Bass", kind: .bass)
                addLayerButton("+ Melody", kind: .melody)
            }
        }
    }

    private func addLayerButton(_ title: String, kind: MusicLayer) -> some View {
        let tint = CodaDesignTokens.Colors.layerTint(kind)
        return Button { store.addExtraLayer(kind: kind) } label: {
            Text(title)
                .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(tint.opacity(0.12), in: Capsule())
        }
        .accessibilityIdentifier("layers.add.\(kind.rawValue)")
    }

    private func wrenchActionButton(_ title: String, symbol: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                Text(title).lineLimit(1).minimumScaleFactor(0.75)
            }
            .font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
            .foregroundStyle(destructive ? CodaDesignTokens.Colors.danger : CodaDesignTokens.Colors.primaryInk)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(destructive ? CodaDesignTokens.Colors.danger.opacity(0.12) : .white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.control))
        }
    }
}

private struct RadialMenuView: View {
    @Bindable var store: CodaEditorStore
    let center: CGPoint
    let mode: String

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(0..<store.radialRings().count, id: \.self) { index in
                    let value = store.radialRings()[index]
                    let (ring, labels, radiusValue, thicknessValue) = value
                    let placement = store.radial?.placement ?? RadialPlacement(origin: center, direction: RadialGeometry.defaultDirection)
                    let layout = RadialRingLayout(count: labels.count, radius: radiusValue,
                        thickness: thicknessValue, direction: placement.direction)
                    let radius = CGFloat(radiusValue * placement.scale)
                    let thickness = CGFloat(thicknessValue * placement.scale)
                    CodaAcrylic(store: store)
                        .clipShape(RadialArcShape(arc: layout.backing, scale: placement.scale))
                        .frame(width: (radius + thickness / 2) * 2, height: (radius + thickness / 2) * 2)
                        .position(center)
                    ForEach(labels.indices, id: \.self) { slot in
                        let enabled = store.radialSlotEnabled(ring, slot: slot)
                        let point = layout.buttonCenter(slot: slot, center: center, scale: placement.scale)
                        let shape = RingSlotShape(layout: layout, index: slot, scale: placement.scale)
                        shape.fill(CodaDesignTokens.Colors.primaryInk.opacity(!enabled
                            ? CodaDesignTokens.EditorSurface.radialDisabledPillOpacity
                            : store.radial?.selectedRing == ring && store.radial?.selectedSlot == slot
                            ? CodaDesignTokens.EditorSurface.radialSelectedPillOpacity
                            : CodaDesignTokens.EditorSurface.radialPillOpacity))
                            .frame(width: (radius + thickness / 2) * 2, height: (radius + thickness / 2) * 2)
                            .position(center)
                        ZStack {
                            if store.isPatternSqueezeMenu {
                                Image(systemName: ProcreateIcons.rollRadialSymbol(for: slot).symbol)
                                    .font(.system(size: CodaDesignTokens.EditorSurface.toolIconSize, weight: .bold))
                                    .accessibilityLabel(labels[slot])
                            } else if labels[slot].hasPrefix("More ") {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.system(size: CodaDesignTokens.EditorSurface.toolIconSize, weight: .black))
                                    .accessibilityLabel(labels[slot])
                            } else if ring == .outer && slot == 3 {
                                Image(systemName: "square.grid.2x2.fill")
                                    .font(.system(size: CodaDesignTokens.EditorSurface.toolIconSize, weight: .black))
                                    .accessibilityLabel("All chord qualities")
                            } else if let tool = store.radialTool(ring: ring, slot: slot) {
                                Image(systemName: tool.symbol)
                                    .font(.system(size: CodaDesignTokens.EditorSurface.toolIconSize,
                                                  weight: CodaDesignTokens.EditorSurface.toolIconWeight))
                                    .accessibilityLabel(tool.title)
                            } else {
                                Text(labels[slot])
                                    .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                                    .accessibilityLabel(labels[slot])
                            }
                        }
                            .foregroundStyle(!enabled
                                             ? CodaDesignTokens.Colors.mutedInk.opacity(0.35)
                                             : store.radial?.selectedRing == ring && store.radial?.selectedSlot == slot
                                             ? CodaDesignTokens.Colors.primaryInk
                                             : store.currentRingIsSelected(ring) ? CodaDesignTokens.Colors.primaryInk
                                             : CodaDesignTokens.Colors.mutedInk)
                            .lineLimit(1).minimumScaleFactor(0.85)
                            .frame(width: layout.buttonDiameter * placement.scale,
                                   height: layout.buttonDiameter * placement.scale)
                            .position(point)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("radial.option.\(String(describing: ring)).\(slot)")
                            .accessibilityValue(enabled ? "available" : "unavailable")
                    }
                }
                Circle().fill(CodaDesignTokens.Colors.primaryInk.opacity(0.6))
                    .frame(width: 8, height: 8).position(center)
                if let preview = store.radialPreview {
                    Text(preview).font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(width: 96, height: 64)
                        .background { CodaAcrylic(store: store).clipShape(Capsule()) }
                        .position(x: min(geometry.size.width - 48, max(48, center.x)),
                                  y: min(geometry.size.height - 32, max(store.stripTop + 32, center.y)))
                }
            }
            // Explicit root coordinates: positioned children must not determine
            // an intrinsic ZStack origin different from Pencil hit testing.
            .frame(width: geometry.size.width, height: geometry.size.height)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("radial.canvas")
        }
        .allowsHitTesting(false)
    }
}

struct RingSlotShape: Shape {
    let layout: RadialRingLayout
    let index: Int
    var scale: Double = 1

    func path(in rect: CGRect) -> Path {
        Path(layout.buttonPath(slot: index, center: CGPoint(x: rect.midX, y: rect.midY), scale: scale))
    }
}

struct RadialArcShape: Shape {
    let arc: RadialArc
    var scale: Double = 1

    func path(in rect: CGRect) -> Path {
        Path(arc.path(center: CGPoint(x: rect.midX, y: rect.midY), scale: scale))
    }
}

private struct HoldMenuView: View {
    @Bindable var store: CodaEditorStore
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.holdCommands.enumerated()), id: \.offset) { index, command in
                HStack(spacing: 12) {
                    Image(systemName: command.symbol).frame(width: 22)
                    Text(command.title)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(command.destructive ? CodaDesignTokens.Colors.danger : CodaDesignTokens.Colors.primaryInk)
                .opacity(command.enabled ? 1 : 0.3)
                .padding(.horizontal, 14)
                .frame(height: CodaDesignTokens.Input.holdRowHeight)
                .background(store.holdMenu?.selectedIndex == index ? .white.opacity(0.1) : .clear)
                .accessibilityIdentifier("hold.command.\(index)")
                if index < store.holdCommands.count - 1 {
                    Rectangle().fill(.white.opacity(0.06)).frame(height: CodaDesignTokens.Input.holdDividerHeight)
                }
            }
        }
        .background { CodaAcrylic(store: store).clipShape(RoundedRectangle(cornerRadius: 10)) }
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .allowsHitTesting(false)
    }
}

private struct KnobResetMenu: View {
    @Bindable var store: CodaEditorStore
    let state: KnobResetState
    var body: some View {
        ZStack {
            CodaAcrylic(store: store).frame(width: 104, height: 104).clipShape(Circle())
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: CodaDesignTokens.EditorSurface.toolIconSize, weight: .black))
                .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
                .accessibilityLabel("Reset to preset default")
        }
        .position(state.center)
        .allowsHitTesting(false)
        .accessibilityIdentifier("radial.knobReset")
    }
}

private struct EditorInlineStatus: View {
    @Bindable var store: CodaEditorStore
    var body: some View {
        Group {
            if let message = store.inlineError ?? store.startupError {
                Text(message)
                    .font(CodaDesignTokens.Typography.font(size: 10, weight: .medium))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background { CodaAcrylic(store: store).clipShape(Capsule()) }
                    .accessibilityIdentifier("editor.inlineError")
            } else if store.audioAvailable {
                Text("Audio active")
                    .font(CodaDesignTokens.Typography.font(size: 9, weight: .bold))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    .accessibilityIdentifier("editor.audioState")
            } else {
                EmptyView()
            }
        }
        .allowsHitTesting(false)
    }
}

extension CodaEditorStore {
    static func pitchName(for pitch: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return names[(pitch % 12 + 12) % 12]
    }
}

private struct PatternOverlayView: View {
    @Bindable var store: CodaEditorStore
    var body: some View {
        Canvas { context, _ in
            let frame = store.patternFrame
            context.clip(to: Path(frame))
            context.fill(Path(frame), with: .color(.black.opacity(0.55)))
            for bar in store.visibleBars {
                for slot in 0..<8 {
                    let x = frame.minX + store.viewport.x(forStep: Double(bar * 16 + slot * 2), in: Double(frame.width))
                    var grid = Path(); grid.move(to: CGPoint(x: x, y: frame.minY)); grid.addLine(to: CGPoint(x: x, y: frame.maxY))
                    context.stroke(grid, with: .color(.white.opacity(slot == 0 ? 0.12 : 0.06)), lineWidth: 1)
                    guard let stroke = store.patternGeometry(bar: bar, slot: slot, preview: store.patternPreview) else { continue }
                    var path = Path()
                    if let radius = stroke.radius {
                        path.addEllipse(in: CGRect(x: stroke.start.x-radius, y: stroke.start.y-radius, width: radius*2, height: radius*2))
                        let inset = radius * 0.65
                        path.move(to: CGPoint(x: stroke.start.x-inset,y: stroke.start.y-inset))
                        path.addLine(to: CGPoint(x: stroke.start.x+inset,y: stroke.start.y+inset))
                        path.move(to: CGPoint(x: stroke.start.x-inset,y: stroke.start.y+inset))
                        path.addLine(to: CGPoint(x: stroke.start.x+inset,y: stroke.start.y-inset))
                    } else {
                        path.move(to: stroke.start); path.addLine(to: stroke.end)
                        var head = Path(); head.addLines(stroke.head); head.closeSubpath()
                        context.fill(head, with: .color(CodaDesignTokens.Colors.chord))
                    }
                    context.stroke(path, with: .color(CodaDesignTokens.Colors.chord), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
            if let label = store.patternReadoutLabel, let point = store.patternPencilPosition {
                let text = context.resolve(Text(label)
                    .font(CodaDesignTokens.Typography.font(size: CodaDesignTokens.Typography.chipAndReadoutSize, weight: .bold))
                    .foregroundColor(CodaDesignTokens.Colors.primaryInk))
                let measured = text.measure(in: frame.size)
                let size = CGSize(width: measured.width + 2 * CodaDesignTokens.EditorSurface.patternReadoutHorizontalPadding,
                                  height: measured.height + 2 * CodaDesignTokens.EditorSurface.patternReadoutVerticalPadding)
                let capsule = PatternReadoutGeometry.frame(near: point, size: size, in: frame)
                context.fill(Path(roundedRect: capsule, cornerRadius: CodaDesignTokens.Radii.control),
                             with: .color(CodaDesignTokens.Colors.darkGlass))
                context.draw(text, at: CGPoint(x: capsule.midX, y: capsule.midY))
            }
        }
        .accessibilityIdentifier("pattern.overlay")
    }
}

private struct PatternControlsView: View {
    @Bindable var store: CodaEditorStore
    // SwiftUI resets the entire draft on successful lift AND cancellation.
    @GestureState private var swingDrag: PatternSwingDrag? = nil

    private var swingValue: Double { swingDrag?.preview ?? store.currentPatternSettings.swing }

    var body: some View {
        HStack(spacing: CodaDesignTokens.Geometry.topBarControlGap) {
            VStack(spacing: 1) {
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 3)
                    Circle().trim(from: 0, to: swingValue)
                        .stroke(CodaDesignTokens.Colors.chord, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(swingValue * 100))")
                        .font(CodaDesignTokens.Typography.font(size: 8, weight: .bold))
                }
                .frame(width: 28, height: 28)
                Text("Swing").font(CodaDesignTokens.Typography.font(size: 8, weight: .medium))
            }
            .frame(width: 44, height: 44)
            .background(Color.white.opacity(0.001))
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0)
                .updating($swingDrag) { value, drag, _ in
                    var next = drag ?? PatternSwingDrag(startValue: store.currentPatternSettings.swing)
                    next.update(verticalTranslation: Double(value.translation.height))
                    drag = next
                    if store.uiDiagnosticsEnabled {
                        store.recordUIEvent("pattern.swing.changed translationY=\(value.translation.height) start=\(next.startValue) draft=\(next.preview)")
                    }
                }.onEnded { value in
                    // GestureState may already have reset. Preview never writes settings,
                    // so the committed setting is still the baseline in that case.
                    let retainedDrag = swingDrag
                    let drag = retainedDrag ?? PatternSwingDrag(startValue: store.currentPatternSettings.swing)
                    let final = drag.valueToCommit(verticalTranslation: Double(value.translation.height))
                    if let final { store.updatePatternSettings(swing: final) }
                    if store.uiDiagnosticsEnabled {
                        store.recordUIEvent("pattern.swing.ended dy=\(value.translation.height) start=\(drag.startValue) retained=\(retainedDrag != nil) requested=\(String(describing: final)) committed=\(store.currentPatternSettings.swing)")
                    }
                })
            .onChange(of: swingDrag == nil) { _, inactive in
                if inactive { store.recordUIEvent("pattern.swing.reset committed=\(store.currentPatternSettings.swing)") }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Swing")
            .accessibilityValue("\(Int(swingValue * 100)) percent")
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 0.05 : -0.05
                store.updatePatternSettings(swing: min(1, max(0, store.currentPatternSettings.swing + delta)))
            }
            .accessibilityIdentifier("pattern.swing")

            Button {
                store.updatePatternSettings(loose: store.currentPatternSettings.humanize == .tight)
            } label: {
                Text(store.currentPatternSettings.humanize == .tight ? "Tight" : "Loose")
                    .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                    .padding(.horizontal, 9)
                    .frame(height: CodaDesignTokens.Geometry.topBarControlHeight)
                    .background(.white.opacity(0.06), in: Capsule())
                    .contentShape(Capsule())
            }
            .accessibilityLabel("Humanize")
            .accessibilityValue(store.currentPatternSettings.humanize == .tight ? "Tight" : "Loose")
            .accessibilityIdentifier("pattern.humanize")
        }
        .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pattern.controls")
        .onAppear { store.recordUIEvent("pattern.controls.appear") }
        .onDisappear { store.recordUIEvent("pattern.controls.disappear") }
    }
}
