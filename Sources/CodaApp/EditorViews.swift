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

    var body: some View {
        GeometryReader { geometry in
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
                                                               weight: .semibold))
                        .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(CodaDesignTokens.Colors.darkGlass, in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.control))
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

                PencilInputBridge(store: store)
                    .frame(width: 1, height: 1)
                    .position(x: -2, y: -2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(name: "editor.root")
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
            Button { store.popup = .appSettings } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .accessibilityIdentifier("top.appSettings")
            Button { store.popup = .projectSettings } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .bold))
                    .frame(width: 32, height: 32)
            }
            .accessibilityIdentifier("top.projectSettings")

            Rectangle().fill(CodaDesignTokens.Colors.primaryInk.opacity(0.08))
                .frame(width: 1, height: 20)
                .padding(.horizontal, 2)

            Button { store.popup = .keyScale } label: {
                HStack(spacing: 6) {
                    Text("\(CodaEditorStore.pitchName(for: store.key.tonic)) \(store.key.mode == .major ? "Maj" : "Min")")
                        .font(CodaDesignTokens.Typography.font(size: 12, weight: .semibold))
                    Text(store.key.mode == .major ? "MAJ" : "NAT")
                        .font(CodaDesignTokens.Typography.font(size: 10, weight: .semibold))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                }
                .padding(.horizontal, 9).frame(height: 32)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.control))
            }
            .accessibilityIdentifier("top.keyScale")
            .accessibilityValue("\(store.key.tonic)-\(store.key.mode == .major ? "major" : "natural minor")")

            HStack(spacing: 4) {
                Text("\(Int(store.tempo.rounded()))")
                    .font(CodaDesignTokens.Typography.font(size: 12, weight: .semibold))
                Text("BPM").font(CodaDesignTokens.Typography.font(size: 10, weight: .semibold))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
            }
            .padding(.horizontal, 9).frame(height: 32)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.control))
            .contentShape(RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.control))
            .onTapGesture { store.popup = .tempo; store.tempoDraft = String(Int(store.tempo.rounded())) }
            .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                if tempoDragStart == nil { tempoDragStart = store.tempo }
                guard let tempoDragStart else { return }
                store.setTempo(tempoDragStart + Double((value.translation.width / 8).rounded()))
            }.onEnded { _ in tempoDragStart = nil })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tempo")
            .accessibilityValue("\(Int(store.tempo.rounded())) BPM")
            .accessibilityIdentifier("top.tempo")

            Text("4/4")
                .font(CodaDesignTokens.Typography.font(size: 12, weight: .semibold))
                .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                .frame(height: 32).padding(.horizontal, 8)
                .accessibilityIdentifier("top.timeSignature")

            Spacer(minLength: 8)

            Button { store.toggleLooping() } label: {
                Image(systemName: "repeat").font(.system(size: 14, weight: .semibold))
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
                    .background(Color.white, in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.control))
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
                Text("CHORDS").font(CodaDesignTokens.Typography.font(size: 11, weight: .semibold))
                    .foregroundStyle(CodaDesignTokens.Colors.chord)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(CodaDesignTokens.Colors.chord.opacity(0.08), in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.innerPill))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("top.activeLayer")

            Button { store.openDrawer() } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .accessibilityIdentifier("top.drawer")

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
        }
        .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
        .padding(.horizontal, CodaDesignTokens.Geometry.topBarHorizontalPadding)
        .frame(height: CodaDesignTokens.Geometry.topBarHeight)
        .background(CodaDesignTokens.Colors.darkGlass)
        .buttonStyle(.plain)
        .popover(item: $store.popup) { popup in
            EditorSettingsPopover(store: store, popup: popup)
                .presentationCompactAdaptation(.popover)
        }
        // Give the container its own AX node so its identifier does not
        // propagate to (and replace the identifiers of) the controls inside.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.topBar")
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
                                                               weight: .semibold))
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
                                    .font(CodaDesignTokens.Typography.font(size: 10, weight: .semibold))
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
                        .font(CodaDesignTokens.Typography.font(size: 10, weight: .semibold))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    Text("Poly 12")
                        .font(CodaDesignTokens.Typography.font(size: 9))
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
                                    .overlay(Text("·").font(CodaDesignTokens.Typography.font(size: 18)).foregroundStyle(CodaDesignTokens.Colors.mutedInk.opacity(0.4)))
                                    .offset(x: CGFloat(store.viewport.x(forStep: Double(start), in: Double(strip.size.width))), y: 6)
                                    .accessibilityElement()
                                    .accessibilityLabel("Empty chord bar \(bar + 1)")
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(store.chordName(region))
                    .font(CodaDesignTokens.Typography.font(size: CodaDesignTokens.Typography.chordNameSize, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.72)
                Spacer(minLength: 1)
                Text(store.romanNumeral(region.chord))
                    .font(CodaDesignTokens.Typography.font(size: 10, weight: .semibold))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    .lineLimit(1)
            }
            if store.detailsVisible || store.hoveredRegionID == region.id {
                Text("\(store.functionLabel(region.chord)) · \(store.voicingLabel(region)) · \(region.pitches.map(store.pitchName).joined(separator: " · "))")
                    .font(CodaDesignTokens.Typography.font(size: 9, weight: .medium))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    .lineLimit(1).minimumScaleFactor(0.7)
                let alterations = store.alterationText(region)
                if !alterations.isEmpty {
                    Text(alterations).font(CodaDesignTokens.Typography.font(size: 9, weight: .semibold))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(CodaDesignTokens.Geometry.chordInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                    .accessibilityIdentifier("editor.pianoRoll")
                }
            }
            .background(CodaDesignTokens.Colors.oled)
        }
        .background(CodaDesignTokens.Colors.oled)
    }

    private func pitchGutter(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            CodaDesignTokens.Colors.coalGutter
            ForEach(0...127, id: \.self) { midi in
                if midi % 12 == 0 {
                    let y = CGFloat(store.viewport.y(forMIDI: midi)) + store.viewport.semitoneHeight / 2
                    HStack(spacing: 4) {
                        Circle().fill(CodaDesignTokens.Colors.primaryInk.opacity(0.35)).frame(width: 3, height: 3)
                        Text(store.pitchName(midi))
                            .font(CodaDesignTokens.Typography.font(size: 10, weight: .semibold))
                            .foregroundStyle(CodaDesignTokens.Colors.primaryInk.opacity(0.45))
                    }
                    .position(x: CodaDesignTokens.Geometry.pitchGutterWidth / 2, y: y)
                    .accessibilityIdentifier("roll.pitch.\(midi)")
                }
            }
        }
        .frame(width: CodaDesignTokens.Geometry.pitchGutterWidth, height: height)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("SYNTH").font(CodaDesignTokens.Typography.font(size: 10, weight: .bold))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    Spacer()
                    Button { store.openDrawer(false) } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .accessibilityIdentifier("drawer.close")
                }
                presetCards
                HStack(spacing: 8) {
                    KnobControl(store: store, knob: .wobble, diameter: 52)
                    KnobControl(store: store, knob: .warmth, diameter: 52)
                }
                .frame(maxWidth: .infinity)
                controlGrid([.cutoff, .resonance, .shape, .detune, .glide])
                Button { withAnimation(.easeOut(duration: CodaDesignTokens.Motion.fade)) { store.fxExpanded.toggle() } } label: {
                    HStack {
                        Text("FX & Mix").font(CodaDesignTokens.Typography.font(size: 12, weight: .semibold))
                        Spacer()
                        Image(systemName: store.fxExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(CodaDesignTokens.Colors.darkGlass, in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.innerPill))
                }
                .accessibilityIdentifier("drawer.fxMix")
                if store.fxExpanded {
                    controlGrid([.delay, .reverb, .chordLevel])
                }
                if let error = store.audioError, !error.isEmpty {
                    Text("Audio error: \(error)")
                        .font(CodaDesignTokens.Typography.font(size: 10))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                        .accessibilityIdentifier("drawer.audioError")
                }
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
        .background(CodaDesignTokens.Colors.darkGlass)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: CodaDesignTokens.Radii.card,
                                          bottomLeadingRadius: CodaDesignTokens.Radii.card))
        .overlay(alignment: .leading) {
            Capsule().fill(CodaDesignTokens.Colors.mutedInk.opacity(0.55))
                .frame(width: 4, height: 40)
                .frame(width: 18, height: 56)
                .contentShape(Rectangle())
                .onTapGesture { store.openDrawer(false) }
                .gesture(DragGesture(minimumDistance: 4).onEnded { value in
                    if value.translation.width > 28 { store.openDrawer(false) }
                })
                .accessibilityIdentifier("drawer.pullTab")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.synthDrawer")
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.width > 60 && abs(value.translation.width) > abs(value.translation.height) {
                store.openDrawer(false)
            }
        })
        .buttonStyle(.plain)
    }

    private var presetCards: some View {
        HStack(spacing: 6) {
            presetCard("Pluck", index: 0)
            presetCard("Currents", index: 1)
            presetCard("Wobble", index: 2)
        }
        .frame(height: 56)
    }

    private func presetCard(_ title: String, index: UInt8) -> some View {
        let selected = store.controls.preset == index
        return Button { store.setPreset(index) } label: {
            VStack(spacing: 5) {
                Circle().fill(selected ? CodaDesignTokens.Colors.chord : .clear)
                    .frame(width: 6, height: 6)
                Text(title).font(CodaDesignTokens.Typography.font(size: 10, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? CodaDesignTokens.Colors.primaryInk : CodaDesignTokens.Colors.mutedInk)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selected ? .white.opacity(0.08) : CodaDesignTokens.Colors.darkGlass,
                        in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card))
        }
        .accessibilityIdentifier("drawer.preset.\(index)")
        .accessibilityValue(selected ? "selected" : "")
    }

    private func controlGrid(_ knobs: [EditorKnob]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(knobs) { knob in KnobControl(store: store, knob: knob, diameter: 42) }
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
                    .font(CodaDesignTokens.Typography.font(size: 10, weight: .semibold))
                    .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text("\(Int((value * 100).rounded()))")
                    .font(CodaDesignTokens.Typography.font(size: CodaDesignTokens.Typography.chipAndReadoutSize,
                                                           weight: .semibold))
                    .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
                    .fixedSize()
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.white.opacity(0.08), in: Capsule())
                    .accessibilityIdentifier("drawer.knob.readout.\(knob.rawValue)")
            }
            Text("Default \(Int((store.presetDefault(for: knob) * 100).rounded()))")
                .font(CodaDesignTokens.Typography.font(size: 8))
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
        Group {
            switch popup {
            case .appSettings:
                VStack(alignment: .leading, spacing: 12) {
                    Text("App Settings").font(CodaDesignTokens.Typography.font(size: 15, weight: .bold))
                    Toggle("Chord details", isOn: $store.detailsVisible)
                        .font(CodaDesignTokens.Typography.font(size: 12, weight: .semibold))
                        .accessibilityIdentifier("settings.chordDetails")
                    Text("Show function, voicing notes and alterations on chord blocks.")
                        .font(CodaDesignTokens.Typography.font(size: 10))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                }
            case .projectSettings:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Project Settings").font(CodaDesignTokens.Typography.font(size: 15, weight: .bold))
                    Text("Grid · 16 steps per bar").font(CodaDesignTokens.Typography.font(size: 12, weight: .semibold))
                        .accessibilityIdentifier("settings.grid")
                    HStack {
                        Text("Loop length").font(CodaDesignTokens.Typography.font(size: 12))
                        Spacer()
                        Picker("Loop bars", selection: Binding(get: { store.loop.length / 16 }, set: { store.setLoopBars($0) })) {
                            ForEach(1...8, id: \.self) { Text("\($0) bars").tag($0) }
                        }
                        .labelsHidden().accessibilityIdentifier("settings.loopLength")
                    }
                    Text(store.audioAvailable ? "Audio output active" : "Audio output starts on Play or Pencil audition")
                        .font(CodaDesignTokens.Typography.font(size: 10))
                        .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                        .accessibilityIdentifier("settings.audioOutput")
                    if let error = store.audioError {
                        Text("\(error)").font(CodaDesignTokens.Typography.font(size: 10))
                            .foregroundStyle(CodaDesignTokens.Colors.mutedInk)
                    }
                }
            case .keyScale:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Key & Scale").font(CodaDesignTokens.Typography.font(size: 15, weight: .bold))
                    Menu("Key: \(CodaEditorStore.pitchName(for: store.key.tonic))") {
                        ForEach(0..<12, id: \.self) { tonic in
                            Button(CodaEditorStore.pitchName(for: tonic)) { store.setKey(tonic: tonic, mode: store.key.mode) }
                        }
                    }
                    .accessibilityIdentifier("settings.key")
                    Menu("Scale: \(store.key.mode == .major ? "Major" : "Natural Minor")") {
                        Button("Major") { store.setKey(tonic: store.key.tonic, mode: .major) }
                        Button("Natural Minor") { store.setKey(tonic: store.key.tonic, mode: .naturalMinor) }
                    }
                    .accessibilityIdentifier("settings.scale")
                    Text("Key changes suggestions and scale shading. Existing chords stay as written.")
                        .font(CodaDesignTokens.Typography.font(size: 10))
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
                        Text("BPM").font(CodaDesignTokens.Typography.font(size: 12, weight: .semibold))
                    }
                    Button("Apply") { store.commitTempoDraft(); store.popup = nil }
                        .accessibilityIdentifier("settings.applyTempo")
                }
            }
        }
        .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
        .padding(16)
        .frame(minWidth: 250, maxWidth: 320)
        .background(CodaDesignTokens.Colors.darkGlass)
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
                    let radius = CGFloat(radiusValue)
                    let thickness = CGFloat(thicknessValue)
                    let isCurrent = store.currentRingIsSelected(ring)
                    Circle().stroke(CodaDesignTokens.Colors.darkGlass.opacity(isCurrent ? 0.95 : 0.55),
                                    lineWidth: thickness)
                        .frame(width: radius * 2, height: radius * 2)
                        .position(center)
                    ForEach(labels.indices, id: \.self) { slot in
                        let count = max(1, labels.count)
                        let enabled = store.radialSlotEnabled(ring, slot: slot)
                        let angle = RadialGeometry.angle(forSlot: slot, count: count) + .pi / Double(count)
                        let point = CGPoint(x: center.x + CGFloat(cos(angle)) * radius,
                                            y: center.y + CGFloat(sin(angle)) * radius)
                        RingSlotShape(count: count, index: slot, radius: radius,
                                      thickness: thickness)
                            .fill(enabled && store.currentRingIsSelected(ring) && store.radial?.selectedSlot == slot
                                  ? CodaDesignTokens.Colors.primaryInk.opacity(0.13)
                                  : CodaDesignTokens.Colors.darkGlass.opacity(enabled ? 0.76 : 0.30))
                            .frame(width: radius * 2, height: radius * 2)
                            .position(center)
                        Text(labels[slot])
                            .font(CodaDesignTokens.Typography.font(size: labels.count > 10 ? 9 : 11,
                                                                   weight: store.radial?.selectedSlot == slot ? .bold : .semibold))
                            .foregroundStyle(!enabled
                                             ? CodaDesignTokens.Colors.mutedInk.opacity(0.35)
                                             : store.radial?.selectedRing == ring && store.radial?.selectedSlot == slot
                                             ? CodaDesignTokens.Colors.primaryInk
                                             : CodaDesignTokens.Colors.mutedInk)
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .frame(width: min(74, max(34, thickness + 24)))
                            .position(point)
                            .accessibilityValue(enabled ? "available" : "unavailable")
                    }
                }
                Circle().fill(CodaDesignTokens.Colors.primaryInk)
                    .frame(width: 8, height: 8).position(center)
                if let preview = store.radialPreview {
                    Text(preview).font(CodaDesignTokens.Typography.font(size: 12, weight: .semibold))
                        .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(CodaDesignTokens.Colors.darkGlass, in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.innerPill))
                        .position(x: center.x, y: min(geometry.size.height - 18, center.y + CodaDesignTokens.Geometry.radialMaximumRadius + 24))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("radial.canvas")
        }
        .allowsHitTesting(false)
    }
}

private struct RingSlotShape: Shape {
    let count: Int
    let index: Int
    let radius: CGFloat
    let thickness: CGFloat

    func path(in rect: CGRect) -> Path {
        guard count > 0 else { return Path() }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = RadialGeometry.angle(forSlot: index, count: count) + 0.015
        let end = start + 2 * .pi / Double(count) - 0.03
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
    private let commands = ["Copy", "Duplicate", "Delete"]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(commands.indices, id: \.self) { index in
                Text(commands[index])
                    .font(CodaDesignTokens.Typography.font(size: 15, weight: .semibold))
                    .foregroundStyle(index == 2 ? CodaDesignTokens.Colors.danger : CodaDesignTokens.Colors.primaryInk)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: CodaDesignTokens.Input.holdRowHeight)
                    .background(store.holdMenu?.selectedIndex == index ? .white.opacity(0.1) : .clear)
                    .accessibilityIdentifier("hold.command.\(index)")
                if index < commands.count - 1 {
                    Rectangle().fill(.white.opacity(0.04)).frame(height: CodaDesignTokens.Input.holdDividerHeight)
                }
            }
        }
        .background(CodaDesignTokens.Colors.darkGlass, in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.card))
        .allowsHitTesting(false)
    }
}

private struct KnobResetMenu: View {
    @Bindable var store: CodaEditorStore
    let state: KnobResetState
    var body: some View {
        ZStack {
            Circle().fill(CodaDesignTokens.Colors.darkGlass).frame(width: 104, height: 104)
            Text("Reset").font(CodaDesignTokens.Typography.font(size: 12, weight: .semibold))
                .foregroundStyle(CodaDesignTokens.Colors.primaryInk)
            Circle().stroke(CodaDesignTokens.Colors.primaryInk.opacity(0.15), lineWidth: 1)
                .frame(width: 88, height: 88)
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
                    .background(CodaDesignTokens.Colors.darkGlass.opacity(0.86), in: RoundedRectangle(cornerRadius: CodaDesignTokens.Radii.innerPill))
                    .accessibilityIdentifier("editor.inlineError")
            } else if store.audioAvailable {
                Text("Audio active")
                    .font(CodaDesignTokens.Typography.font(size: 9, weight: .semibold))
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
