import SwiftUI
import UIKit
import CodaMusic
import CodaSession
import CodaInteraction

private struct KnobFramesKey: PreferenceKey {
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
                }

                if store.radial != nil, let center = store.radialCenter {
                    RadialMenuView(store: store, center: center, mode: store.radialModeName ?? "primary")
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityIdentifier("radial.menu.\(store.radialModeName ?? "primary")")
                        .zIndex(8)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: UnitPoint(x: center.x / max(1, geometry.size.width), y: center.y / max(1, geometry.size.height)))))
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

                if let popup = activePopup, let anchor = frames[popup] {
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
                        .offset(x: frame.minX, y: frame.minY)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("editor.root")) } action: {
                            store.recordPopupFrame($0, popup: popup)
                        }
                        .onAppear { store.recordUIEvent("popup.appear.\(popup.rawValue)") }
                        .onDisappear { store.recordUIEvent("popup.disappear.\(popup.rawValue)") }
                        .zIndex(20)
                }

                PencilInputBridge(store: store)
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
        HStack(spacing: CodaDesignTokens.Geometry.topBarControlGap) {
            Button { store.presentSettings(.appSettings) } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 15, weight: .black))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .modifier(SettingsAnchor(store: store, popup: .appSettings))
            .accessibilityLabel("App Settings")
            .accessibilityIdentifier("top.appSettings")
            Button { store.presentSettings(.projectSettings) } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .bold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .modifier(SettingsAnchor(store: store, popup: .projectSettings))
            .accessibilityLabel("Project Settings")
            .accessibilityIdentifier("top.projectSettings")

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
                .frame(height: 32).padding(.horizontal, 8)
                .accessibilityIdentifier("top.timeSignature")

            Spacer(minLength: 8)

            Button { store.toggleLooping() } label: {
                Image(systemName: "repeat").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(store.looping ? CodaDesignTokens.Colors.chord : CodaDesignTokens.Colors.mutedInk)
                    .frame(width: 32, height: 32)
                    .shadow(color: store.looping ? CodaDesignTokens.Colors.chord.opacity(0.24) : .clear, radius: 8)
            }
            .accessibilityIdentifier("top.loop")
            .accessibilityValue(store.looping ? "on" : "off")

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

            Button { store.toggleChordMute() } label: {
                Circle().fill(store.controls.muted == 0 ? CodaDesignTokens.Colors.chord : .clear)
                    .overlay(Circle().stroke(CodaDesignTokens.Colors.chord.opacity(0.55), lineWidth: 1.5))
                    .frame(width: 14, height: 14)
                    .frame(width: 32, height: 32)
                    // Keep the full target live when the muted ring has a clear center.
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("top.chordMute")
            .accessibilityValue(store.controls.muted == 0 ? "sounding" : "muted")

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Circle().fill(CodaDesignTokens.Colors.chord).frame(width: 6, height: 6)
                Text("CHORDS").font(CodaDesignTokens.Typography.font(size: 11, weight: .bold))
                    .foregroundStyle(CodaDesignTokens.Colors.chord)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(CodaDesignTokens.Colors.chord.opacity(0.08), in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.innerPill))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("top.activeLayer")

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
            Capsule().fill(CodaDesignTokens.Colors.primaryInk.opacity(0.65))
                .frame(width: CodaDesignTokens.EditorSurface.drawerHandleWidth,
                       height: CodaDesignTokens.EditorSurface.drawerHandleHeight)
                .frame(width: CodaDesignTokens.EditorSurface.drawerTabWidth,
                       height: CodaDesignTokens.EditorSurface.drawerTabHeight)
                .background { CodaAcrylic(store: store).clipShape(Capsule()) }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.drawerOpen ? "Close synth drawer" : "Open synth drawer")
        .accessibilityIdentifier("drawer.pullTab")
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
                        Text("SNAP")
                            .accessibilityIdentifier("timeline.snap.caption")
                    }
                        .font(CodaDesignTokens.Typography.font(size: CodaDesignTokens.Typography.noteAndLabelSize,
                                                               weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                        .fixedSize()
                        .frame(width: CodaDesignTokens.Geometry.timelineHeaderWidth, height: geometry.size.height)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("timeline.snap")
                    GeometryReader { ruler in
                        ZStack(alignment: .topLeading) {
                            ForEach(0..<MusicDefaults.canvasBars, id: \.self) { bar in
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
                        ForEach(0..<MusicDefaults.canvasBars, id: \.self) { bar in
                            let start = bar * MusicDefaults.stepsPerBar
                            let occupied = store.regions.contains { $0.start < start + MusicDefaults.stepsPerBar && $0.end > start }
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
                        ForEach(store.regions, id: \.id) { region in
                            let x = CGFloat(store.viewport.x(forStep: Double(region.start), in: Double(strip.size.width)))
                            let width = max(10, CGFloat(store.viewport.stepWidth(in: Double(strip.size.width)) * Double(region.length)))
                            ChordBlockView(store: store, region: region)
                                .frame(width: width, height: 92)
                                .offset(x: x, y: 6)
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
            Text(store.chordName(region))
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
        GeometryReader { geometry in
            HStack(spacing: 0) {
                pitchGutter(height: geometry.size.height)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        drawGrid(in: &context, size: size)
                        drawNotes(in: &context, size: size)
                        drawPlayhead(in: &context, size: size)
                    }
                    .background(CodaDesignTokens.Colors.oled)
                    .contentShape(Rectangle())
                    .onTapGesture { if store.drawerOpen { store.openDrawer(false) } }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Read-only chord piano roll")
                    .accessibilityIdentifier("editor.pianoRoll")
                }
            }
            .background(CodaDesignTokens.Colors.oled)
        }
        .background(CodaDesignTokens.Colors.oled)
        .clipped()
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
            let color = store.scaleContains(midi) ? CodaDesignTokens.Colors.coalScale : CodaDesignTokens.Colors.oled
            context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: row)), with: .color(color))
            var horizontal = Path(); horizontal.move(to: CGPoint(x: 0, y: y)); horizontal.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(horizontal, with: .color(CodaDesignTokens.Colors.primaryInk.opacity(0.025)), lineWidth: 0.5)
        }
        for step in 0...store.totalSteps {
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
        for region in store.regions {
            let x = CGFloat(store.viewport.x(forStep: Double(region.start), in: Double(size.width)))
            let endX = CGFloat(store.viewport.x(forStep: Double(region.end), in: Double(size.width)))
            for pitch in region.pitches {
                let y = CGFloat(store.viewport.y(forMIDI: pitch))
                let row = CGFloat(store.viewport.semitoneHeight)
                guard y + row >= 0, y < size.height, endX > 0, x < size.width else { continue }
                let note = CGRect(x: max(0, x), y: y + CodaDesignTokens.Geometry.noteMicroInset,
                                  width: max(0, min(size.width, endX) - max(0, x)),
                                  height: max(1, row - CodaDesignTokens.Geometry.noteMicroInset * 2))
                let root = pitch % 12 == region.chord.root
                let opacity = store.selectedRegionID == region.id ? 0.95 : 0.78
                            context.fill(Path(roundedRect: note, cornerSize: CGSize(width: CodaDesignTokens.Radii.control,
                                                                                   height: CodaDesignTokens.Radii.control)),
                             with: .color((root ? CodaDesignTokens.Colors.chordAlternate : CodaDesignTokens.Colors.chord).opacity(opacity)))
            }
        }
    }

    private func drawPlayhead(in context: inout GraphicsContext, size: CGSize) {
        let x = CGFloat(store.viewport.x(forStep: Double(store.playheadStep), in: Double(size.width)))
        guard x >= 0, x <= size.width else { return }
        var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(CodaDesignTokens.Colors.primaryInk.opacity(0.35)), lineWidth: 1)
    }
}

private struct SynthDrawer: View {
    @Bindable var store: CodaEditorStore

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Deliberately empty reserved structure, without sidekick UI.
                Color.clear
                    .frame(height: geometry.size.height * CodaDesignTokens.EditorSurface.drawerReservedFraction)
                    .accessibilityHidden(true)
                ScrollView {
                    VStack(alignment: .leading, spacing: CodaDesignTokens.EditorSurface.drawerSectionGap) {
                        HStack {
                            Text("SYNTH")
                                .font(CodaDesignTokens.Typography.font(size: 15, weight: .black))
                            Spacer()
                            Button { store.openDrawer(false) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: CodaDesignTokens.EditorSurface.toolIconSize, weight: .black))
                                    .frame(width: CodaDesignTokens.EditorSurface.drawerCloseSize,
                                           height: CodaDesignTokens.EditorSurface.drawerCloseSize)
                            }
                            .accessibilityLabel("Close synth drawer")
                            .accessibilityIdentifier("drawer.close")
                        }
                        section("PRESETS") { presetCards }
                        section("MACROS") {
                            HStack(spacing: CodaDesignTokens.EditorSurface.drawerControlGap) {
                                KnobControl(store: store, knob: .wobble, diameter: CodaDesignTokens.EditorSurface.drawerMacroDiameter)
                                KnobControl(store: store, knob: .warmth, diameter: CodaDesignTokens.EditorSurface.drawerMacroDiameter)
                            }
                        }
                        section("SOUND") {
                            controlGrid([.cutoff, .resonance, .shape, .detune, .glide])
                        }
                        VStack(spacing: CodaDesignTokens.EditorSurface.drawerControlGap) {
                            Button { store.fxExpanded.toggle() } label: {
                                HStack {
                                    Image(systemName: "waveform.circle.fill")
                                        .font(.system(size: CodaDesignTokens.EditorSurface.toolIconSize, weight: .black))
                                    Text("FX & Mix").font(CodaDesignTokens.Typography.font(size: 13, weight: .bold))
                                    Spacer()
                                    Image(systemName: store.fxExpanded ? "minus.circle.fill" : "plus.circle.fill")
                                        .font(.system(size: 18, weight: .black))
                                }
                                .padding(.horizontal, CodaDesignTokens.EditorSurface.drawerPadding)
                                .frame(height: CodaDesignTokens.EditorSurface.fxRowHeight)
                                .background(.white.opacity(0.06), in: Capsule())
                            }
                            .accessibilityIdentifier("drawer.fxMix")
                            .accessibilityValue(store.fxExpanded ? "expanded" : "collapsed")
                            if store.fxExpanded {
                                section("SHARED FX / CHORDS LEVEL") {
                                    controlGrid([.delay, .reverb, .chordLevel])
                                }
                            }
                        }
                        if let error = store.audioError, !error.isEmpty {
                            Text("Audio error: \(error)")
                                .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                                .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                                .accessibilityIdentifier("drawer.audioError")
                        }
                    }
                    .padding(CodaDesignTokens.EditorSurface.drawerPadding)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("drawer.synthScroll")
                .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
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

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: CodaDesignTokens.EditorSurface.drawerControlGap) {
            Text(title).font(CodaDesignTokens.Typography.font(size: 10, weight: .black))
                .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
            content()
        }
    }

    private var presetCards: some View {
        HStack(spacing: CodaDesignTokens.Geometry.topBarControlGap) {
            presetCard("Pluck", index: 0)
            presetCard("Currents", index: 1)
            presetCard("Wobble", index: 2)
        }
        .frame(height: CodaDesignTokens.EditorSurface.drawerPresetHeight)
    }

    private func presetCard(_ title: String, index: UInt8) -> some View {
        let selected = store.controls.preset == index
        return Button { store.setPreset(index) } label: {
            VStack(spacing: 5) {
                Circle().fill(selected ? CodaDesignTokens.Colors.chord : CodaDesignTokens.Colors.mutedInk.opacity(0.2))
                    .frame(width: 6, height: 6)
                Text(title).font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? CodaDesignTokens.Colors.primaryInk : CodaDesignTokens.Colors.mutedInk)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(selected ? 0.12 : 0.04), in: Capsule())
        }
        .accessibilityIdentifier("drawer.preset.\(index)")
        .accessibilityValue(selected ? "selected" : "")
    }

    private func controlGrid(_ knobs: [EditorKnob]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                  spacing: CodaDesignTokens.EditorSurface.drawerControlGap) {
            ForEach(knobs) { knob in
                KnobControl(store: store, knob: knob, diameter: CodaDesignTokens.EditorSurface.drawerKnobDiameter)
            }
        }
        .frame(maxWidth: .infinity)
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
            case .appSettings:
                VStack(alignment: .leading, spacing: 12) {
                    Text("App Settings").font(CodaDesignTokens.Typography.font(size: 15, weight: .bold))
                    Toggle("Chord details", isOn: $store.detailsVisible)
                        .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                        .accessibilityIdentifier("settings.chordDetails")
                    Text("Show function, voicing notes and alterations on chord blocks.")
                        .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                }
            case .projectSettings:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Project Settings").font(CodaDesignTokens.Typography.font(size: 15, weight: .bold))
                    Text("Grid · 16 steps per bar").font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                        .accessibilityIdentifier("settings.grid")
                    Text("Chord starts · whole bars\nResize · 1/16 steps")
                        .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                        .accessibilityIdentifier("settings.chordPlacement")
                    HStack {
                        Text("Loop length").font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                        Spacer()
                        Stepper("\(store.loop.length / 16)", value: Binding(
                            get: { store.loop.length / 16 }, set: { store.setLoopBars($0) }), in: 1...8)
                            .font(CodaDesignTokens.Typography.font(size: 12, weight: .bold))
                            .accessibilityIdentifier("settings.loopLength")
                    }
                    Text(store.audioAvailable ? "Audio output active" : "Audio output starts on Play or Pencil audition")
                        .font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                        .accessibilityIdentifier("settings.audioOutput")
                    if let error = store.audioError {
                        Text("\(error)").font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                            .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    }
                }
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
        .frame(width: CodaDesignTokens.EditorSurface.popupWidth)
        .background { CodaAcrylic(store: store) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.popup.\(popup.rawValue)")
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
                    let radius = CGFloat(radiusValue * placement.scale)
                    let thickness = CGFloat(thicknessValue * placement.scale)
                    ForEach(labels.indices, id: \.self) { slot in
                        let count = max(1, labels.count)
                        let enabled = store.radialSlotEnabled(ring, slot: slot)
                        let angle = RadialGeometry.angle(forSlot: slot, count: count, direction: placement.direction)
                            + RadialGeometry.sweep / Double(count) / 2
                        let point = placement.point(radius: radiusValue, angle: angle)
                        let shape = RingSlotShape(count: count, index: slot, radius: radius,
                                                  thickness: thickness, direction: placement.direction)
                        CodaAcrylic(store: store)
                            .overlay(CodaDesignTokens.Colors.primaryInk.opacity(
                                enabled && store.radial?.selectedRing == ring && store.radial?.selectedSlot == slot ? 0.13 : 0))
                            .clipShape(shape)
                            .frame(width: (radius + thickness / 2) * 2, height: (radius + thickness / 2) * 2)
                            .position(center)
                        Group {
                            if labels[slot].hasPrefix("More ") {
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
                            .frame(width: min(84, 2 * radius * CGFloat(sin(RadialGeometry.sweep / Double(count) / 2)) - 4))
                            .position(point)
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
    let count: Int
    let index: Int
    let radius: CGFloat
    let thickness: CGFloat
    var direction: Double = RadialGeometry.defaultDirection

    func path(in rect: CGRect) -> Path {
        guard count > 0 else { return Path() }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = RadialGeometry.angle(forSlot: index, count: count, direction: direction) + RadialGeometry.slotGap
        let end = start + RadialGeometry.sweep / Double(count) - 2 * RadialGeometry.slotGap
        var path = Path()
        path.addArc(center: center, radius: radius + thickness / 2,
                    startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        path.addArc(center: center, radius: max(0, radius - thickness / 2),
                    startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
        path.closeSubpath()
        return path
    }
}

private struct HoldMenuView: View {
    @Bindable var store: CodaEditorStore
    private let commands: [ChordTool] = [.copy, .duplicate, .delete]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(commands.indices, id: \.self) { index in
                Image(systemName: commands[index].symbol)
                    .font(.system(size: CodaDesignTokens.EditorSurface.toolIconSize,
                                  weight: CodaDesignTokens.EditorSurface.toolIconWeight))
                    .accessibilityLabel(commands[index].title)
                    .foregroundStyle(index == 2 ? CodaDesignTokens.Colors.danger : CodaDesignTokens.Colors.primaryInk)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: CodaDesignTokens.Input.holdRowHeight)
                    .background(store.holdMenu?.selectedIndex == index ? .white.opacity(0.1) : .clear)
                    .accessibilityIdentifier("hold.command.\(index)")
                if index < commands.count - 1 {
                    Rectangle().fill(.white.opacity(0.04)).frame(height: CodaDesignTokens.Input.holdDividerHeight)
                }
            }
        }
        .modifier(AcrylicPanel(store: store))
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
