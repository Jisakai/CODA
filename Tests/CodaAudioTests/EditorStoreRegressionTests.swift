import XCTest
import SwiftUI
import UIKit
import CodaMusic
import CodaInteraction
import CodaNative
@testable import CodaSession

/// Calls the production store ingress and actual offline session. These are
/// dispatch/model regressions, not a substitute for real Pencil hardware tests.
final class EditorStoreRegressionTests: XCTestCase {
    @MainActor
    func testPencilCoordinatorImplementsTheActualOptionalSqueezeSelector() throws {
        let store = try makeStore()
        defer { store.session?.suspend() }
        let coordinator = PencilInputBridge.Coordinator(store: store)
        XCTAssertTrue(coordinator.responds(to:
            #selector(UIPencilInteractionDelegate.pencilInteraction(_:didReceiveSqueeze:))))
    }

    @MainActor
    private func makeStore() throws -> CodaEditorStore {
        let vocabulary = try ChordVocabulary.load(in: Bundle(for: Self.self))
        let session = try MusicSession(vocabulary: vocabulary, offline: true)
        let chord = try Chord(root: 0, qualityID: "minor7")
        try session.edit([.add(ChordRegion(id: "a", chord: chord, start: 0, length: 16,
            pitches: [60, 63, 67, 70]))])
        return CodaEditorStore(session: session)
    }

    @MainActor
    private func point(_ store: CodaEditorStore, ring: RadialRing, slot: Int) throws -> CGPoint {
        let state = try XCTUnwrap(store.radial)
        let layout = try XCTUnwrap(store.radialRings().first { $0.0 == ring })
        let angle = RadialGeometry.angle(forSlot: slot, count: layout.1.count) + .pi / Double(layout.1.count)
        return CGPoint(x: state.center.x + cos(angle) * layout.2,
                       y: state.center.y + sin(angle) * layout.2)
    }

    @MainActor
    func testVisibleHoldRowsDispatchCopyDuplicateDeleteAndOutsideCancels() throws {
        for index in 0..<3 {
            let store = try makeStore()
            defer { store.session?.suspend() }
            store.holdMenu = HoldMenuState(regionID: "a", origin: CGPoint(x: 100, y: 100))
            let frame = try XCTUnwrap(store.holdMenuLayout?.frame)
            let location = CGPoint(x: frame.midX, y: frame.minY + Double(index * 41) + 20)
            store.hoverHoldCommand(at: location)
            XCTAssertEqual(store.holdMenu?.selectedIndex, index)
            store.pencilTouchEnded(at: location)
            XCTAssertEqual(store.regionCount, [1, 2, 0][index])
            if index == 0 {
                store.openSqueeze(at: CGPoint(x: 260, y: 100)) // empty bar 2
                let paste = try point(store, ring: .inner, slot: 0)
                store.pencilTouchEnded(at: paste)
                XCTAssertEqual(store.regionCount, 2, "Visible Copy must really populate the chord clipboard")
            } else {
                try store.session?.undo()
                XCTAssertEqual(store.regionCount, 1)
            }
        }
        let store = try makeStore()
        defer { store.session?.suspend() }
        for location in [CGPoint(x: 99, y: 278), CGPoint(x: 325, y: 278), CGPoint(x: 200, y: 175),
                         CGPoint(x: 200, y: 298), CGPoint(x: 200, y: 216.5)] {
            store.holdMenu = HoldMenuState(regionID: "a", origin: CGPoint(x: 100, y: 100), selectedIndex: 2)
            store.pencilTouchEnded(at: location)
            XCTAssertEqual(store.regionCount, 1, "A stale Delete hover must not commit outside its actual row")
        }
    }

    @MainActor
    func testRootAndQualitySwapIsOneTransactionAndCancelPreservesRedo() throws {
        let store = try makeStore()
        let session = try XCTUnwrap(store.session)
        defer { session.suspend() }
        let original = session.editor.progression
        // Establish redo without changing the original target.
        try session.edit([.resize(id: "a", start: 0, length: 15)])
        try session.undo()
        store.openSqueeze(at: CGPoint(x: 100, y: 100))
        store.pencilTouchEnded(at: try point(store, ring: .inner, slot: 0))
        XCTAssertEqual(store.radial?.mode, .roots)
        store.pencilTouchEnded(at: try point(store, ring: .roots, slot: 7))
        XCTAssertEqual(store.radial?.mode, .all)
        XCTAssertEqual(store.radial?.draft?.root, 7)
        XCTAssertEqual(session.editor.progression, original)
        XCTAssertTrue(session.editor.canRedo)
        store.pencilTouchCancelled()
        XCTAssertEqual(session.editor.progression, original)
        XCTAssertTrue(session.editor.canRedo)

        store.openSqueeze(at: CGPoint(x: 100, y: 100))
        store.pencilTouchEnded(at: try point(store, ring: .inner, slot: 0))
        store.pencilTouchEnded(at: try point(store, ring: .roots, slot: 7))
        let slot = try XCTUnwrap(store.qualities(for: .major).firstIndex { $0.id == "major7" })
        store.pencilTouchEnded(at: try point(store, ring: .major, slot: slot))
        XCTAssertEqual(store.regions.first?.chord, try Chord(root: 7, qualityID: "major7"))
        XCTAssertFalse(session.editor.canRedo)
        try session.undo()
        XCTAssertEqual(session.editor.progression, original, "One undo restores root AND quality")
        try session.redo()
        XCTAssertEqual(store.regions.first?.chord.root, 7)
    }

    @MainActor
    func testOuterExtensionAndAllKeepOriginalRoot() throws {
        let store = try makeStore()
        defer { store.session?.suspend() }
        store.openSqueeze(at: CGPoint(x: 100, y: 100))
        store.pencilTouchEnded(at: try point(store, ring: .outer, slot: 0))
        XCTAssertEqual(store.regions.first?.chord.root, 0)
        store.openSqueeze(at: CGPoint(x: 100, y: 100))
        store.pencilTouchEnded(at: try point(store, ring: .outer, slot: 3))
        let slot = try XCTUnwrap(store.qualities(for: .major).firstIndex { $0.id == "major7" })
        store.pencilTouchEnded(at: try point(store, ring: .major, slot: slot))
        XCTAssertEqual(store.regions.first?.chord, try Chord(root: 0, qualityID: "major7"))
    }

    @MainActor
    func testSlowAndFastEdgePansOpenAndCloseWithoutPanningCanvas() throws {
        for increments in [[CGFloat](repeating: -10, count: 10), [-100]] {
            let store = try makeStore()
            defer { store.session?.suspend() }
            let start = CGPoint(x: store.rootSize.width - 5, y: 400)
            XCTAssertTrue(store.beginFingerNavigation(at: start))
            let before = store.viewport
            var x = start.x
            for delta in increments {
                x += delta
                store.routeFingerPan(from: start, to: CGPoint(x: x, y: start.y), translation: CGPoint(x: delta, y: 0))
            }
            XCTAssertTrue(store.drawerOpen)
            XCTAssertEqual(store.viewport, before)
            XCTAssertTrue(store.beginFingerNavigation(at: start))
            x = start.x
            for _ in 0..<10 {
                x += 10
                store.routeFingerPan(from: start, to: CGPoint(x: x, y: start.y), translation: CGPoint(x: 10, y: 0))
            }
            XCTAssertFalse(store.drawerOpen)
            XCTAssertEqual(store.viewport, before)
        }
        let store = try makeStore()
        defer { store.session?.suspend() }
        XCTAssertTrue(store.beginFingerNavigation(at: CGPoint(x: 400, y: 400)))
        store.routeFingerPan(from: CGPoint(x: 400, y: 400), to: CGPoint(x: 400, y: 350),
                             translation: CGPoint(x: 0, y: -50))
        XCTAssertEqual(store.viewport.verticalOffset, 50)
        XCTAssertFalse(store.drawerOpen)
    }

    @MainActor
    func testScrolledKnobFramesDriveRollResetAndVisibleClipping() throws {
        let store = try makeStore()
        defer { store.session?.suspend() }
        store.drawerOpen = true
        store.fxExpanded = true
        let x = store.rootSize.width - 200
        store.knobFrames = [.cutoff: CGRect(x: x, y: 400, width: 42, height: 42)]
        XCTAssertEqual(store.knob(at: CGPoint(x: x + 21, y: 421)), .cutoff)
        // The same screen location now contains Reverb after drawer scrolling.
        store.knobFrames = [.cutoff: CGRect(x: x, y: 100, width: 42, height: 42),
                            .reverb: CGRect(x: x, y: 400, width: 42, height: 42)]
        let at = CGPoint(x: x + 21, y: 421)
        XCTAssertEqual(store.knob(at: at), .reverb)
        XCTAssertNil(store.knob(at: CGPoint(x: x + 21, y: 121)), "Clipped controls cannot receive Pencil input")
        let cutoff = store.value(for: .cutoff)
        let reverb = store.value(for: .reverb)
        store.pencilHover(at: at, rollAngle: 0)
        store.pencilHover(at: at, rollAngle: .pi / 2)
        XCTAssertGreaterThan(store.value(for: .reverb), reverb)
        XCTAssertEqual(store.value(for: .cutoff), cutoff)
        store.openSqueeze(at: at)
        XCTAssertEqual(store.knobReset?.knob, .reverb)
        store.commitKnobReset()
        XCTAssertEqual(store.value(for: .reverb), store.presetDefault(for: .reverb), accuracy: 1e-6)
        store.fxExpanded = false
        XCTAssertNil(store.knob(at: at))
        store.drawerOpen = false
        XCTAssertNil(store.knob(at: at))
    }

    @MainActor
    func testEveryPresetControlUsesProductionDefaultsAndSharedControlsSurvive() throws {
        let store = try makeStore()
        defer { store.session?.suspend() }
        store.setValue(0.42, for: .chordLevel)
        store.setValue(0.31, for: .delay)
        store.setValue(0.27, for: .reverb)
        for preset in UInt8(0)...UInt8(2) {
            store.setPreset(preset)
            for knob in [EditorKnob.wobble, .warmth, .cutoff, .resonance, .shape, .detune, .glide] {
                XCTAssertEqual(store.value(for: knob), store.presetDefault(for: knob), accuracy: 1e-6)
            }
            XCTAssertEqual(store.value(for: .chordLevel), 0.42, accuracy: 1e-6)
            XCTAssertEqual(store.value(for: .delay), 0.31, accuracy: 1e-6)
            XCTAssertEqual(store.value(for: .reverb), 0.27, accuracy: 1e-6)
        }
    }

    @MainActor
    func testRadialHoverActuallyAuditionsAndCancellationPreservesRedo() async throws {
        let store = try makeStore()
        let session = try XCTUnwrap(store.session)
        defer { store.cancelRadialPreview(); session.suspend() }
        try session.edit([.resize(id: "a", start: 0, length: 15)])
        try session.undo()
        let original = session.editor.progression
        store.openSqueeze(at: CGPoint(x: 100, y: 100))
        let hover = try point(store, ring: .outer, slot: 0)
        store.pencilHover(at: hover, rollAngle: nil)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(session.available, "Preview must reach the real session, not just a text label")
        _ = try session.renderOffline(frames: 1)
        let delivered = session.status().delivered
        XCTAssertGreaterThan(delivered, 0)
        for _ in 0..<20 { store.pencilHover(at: hover, rollAngle: nil) }
        try await Task.sleep(for: .milliseconds(30))
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().delivered, delivered, "Repeated hover of one choice cannot retrigger notes")
        store.pencilHover(at: try XCTUnwrap(store.radial?.center), rollAngle: nil)
        _ = try session.renderOffline(frames: 1)
        XCTAssertGreaterThan(session.status().delivered, delivered, "Dead-zone cancellation releases preview voices")
        XCTAssertEqual(session.editor.progression, original)
        XCTAssertTrue(session.editor.canRedo)
        store.closeRadial()
        let cancelled = session.status().delivered
        try await Task.sleep(for: .milliseconds(200))
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().delivered, cancelled, "No delayed preview may escape menu cancellation")
    }

    @MainActor
    func testStalePreviewCancelCannotStopNewExplicitAuditionOrReopenSuspendedSession() throws {
        let store = try makeStore()
        let session = try XCTUnwrap(store.session)
        defer { session.suspend() }
        let owner = UUID()
        try session.auditionPreview(chord: Chord(root: 7, qualityID: "major7"), owner: owner)
        _ = try session.renderOffline(frames: 1)
        try session.audition(regionID: "a")
        _ = try session.renderOffline(frames: 1)
        let delivered = session.status().delivered
        session.cancelAuditionPreview(owner: owner)
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().delivered, delivered)
        session.suspend()
        session.cancelAuditionPreview(owner: owner)
        XCTAssertFalse(session.available)
    }

    @MainActor
    func testPreviewCancellationSurvivesMailboxPressureAndRestoresPlayback() async throws {
        let store = try makeStore()
        let session = try XCTUnwrap(store.session)
        defer { session.suspend() }
        try session.play()
        _ = try session.renderOffline(frames: 1)
        let owner = UUID()
        try session.auditionPreview(chord: Chord(root: 7, qualityID: "major7"), owner: owner)
        session.cancelAuditionPreview(owner: owner) // preview still occupies mailbox
        _ = try session.renderOffline(frames: 1)
        let auditioning = session.status().delivered
        try await Task.sleep(for: .milliseconds(30)) // production pump retries empty command
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().delivered, auditioning + 8, "Release preview then restore the four playback voices")
        XCTAssertTrue(session.playing)
        XCTAssertEqual(session.status().failures, 0)
    }

    @MainActor
    func testRapidChoicesCoalesceAndSuspensionInvalidatesQueuedPreview() async throws {
        let store = try makeStore()
        let session = try XCTUnwrap(store.session)
        defer { store.cancelRadialPreview(); session.suspend() }
        store.openSqueeze(at: CGPoint(x: 100, y: 100))
        store.pencilHover(at: try point(store, ring: .outer, slot: 0), rollAngle: nil)
        try await Task.sleep(for: .milliseconds(30))
        _ = try session.renderOffline(frames: 1)
        store.pencilHover(at: try point(store, ring: .outer, slot: 1), rollAngle: nil)
        store.pencilHover(at: try point(store, ring: .outer, slot: 2), rollAngle: nil)
        _ = try session.renderOffline(frames: 1) // consumes prior preview release
        let before = session.status().delivered
        try await Task.sleep(for: .milliseconds(40))
        _ = try session.renderOffline(frames: 1)
        XCTAssertEqual(session.status().delivered, before, "New choices must respect the 150ms minimum interval")
        session.suspend() // queued hover belongs to an obsolete lifecycle epoch
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(session.available, "A delayed preview must never reopen a backgrounded session")
    }

    @MainActor
    func testFingerControlsCannotCreatePencilFeedbackEvents() throws {
        let store = try makeStore()
        defer { store.session?.suspend() }
        store.setValue(0, for: .cutoff)
        store.setValue(1, for: .cutoff)
        XCTAssertEqual(store.pencilFeedbackSerial, 0)
        store.rollKnob(.cutoff, angle: 0, at: CGPoint(x: 1200, y: 400))
        store.rollKnob(.cutoff, angle: -.pi / 2, at: CGPoint(x: 1200, y: 400))
        XCTAssertEqual(store.pencilFeedbackSerial, 1)
        XCTAssertFalse(store.pencilFeedbackIsCompletion)
        store.visualDetent = 0
        XCTAssertEqual(store.pencilFeedbackSerial, 1, "Flash expiry is not a new haptic event")
    }
}
