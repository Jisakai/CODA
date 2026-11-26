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
    func testHostedProductionCanvasReceivesAnchorsAndRendersEverySettingsAction() async throws {
        let store = try makeStore(uiDiagnosticsEnabled: true)
        let host = UIHostingController(rootView: CodaCanvas(store: store))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previousKeyWindow = scene?.windows.first { $0.isKeyWindow }
        let window = scene.map { UIWindow(windowScene: $0) }
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 1366, height: 1024))
        let anchors = expectation(description: "Actual root preference receipt")
        var receivedAnchors = false
        store.uiEventObserver = { event in
            if event.hasPrefix("anchors.root"), store.uiAnchorFrames["root"]?.count == 4, !receivedAnchors {
                receivedAnchors = true
                anchors.fulfill()
            }
        }
        defer {
            store.uiEventObserver = nil
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
            store.session?.suspend()
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        await fulfillment(of: [anchors], timeout: 5)

        let rootFrames = try XCTUnwrap(store.uiAnchorFrames["root"])
        XCTAssertEqual(rootFrames.count, 4)
        XCTAssertEqual(store.uiAnchorFrames["topBar.content"], rootFrames)
        XCTAssertEqual(store.uiAnchorFrames["topBar.acrylic"], rootFrames,
                       "The real shared acrylic background must preserve control preferences")
        for surface in [EditorPopup.appSettings, .projectSettings, .keyScale, .tempo] {
            let anchor = try XCTUnwrap(rootFrames[surface])
            XCTAssertEqual(store.uiAnchorFrames["producer.\(surface.rawValue)"]?[surface], anchor)
            XCTAssertEqual(anchor.height, 32, accuracy: 1)
            if surface == .appSettings || surface == .projectSettings {
                XCTAssertEqual(anchor.width, 32, accuracy: 1)
            }
            XCTAssertTrue(window.bounds.contains(anchor))
            let appeared = expectation(description: "Production popup appeared: \(surface)")
            let measured = expectation(description: "Production popup laid out: \(surface)")
            var receivedGeometry = false
            store.uiEventObserver = { event in
                if event == "popup.appear.\(surface.rawValue)" { appeared.fulfill() }
                if event.hasPrefix("popup.geometry.\(surface.rawValue)"), !receivedGeometry {
                    receivedGeometry = true
                    measured.fulfill()
                }
            }
            // Same action used by the production top bar; XCUI separately tests
            // actual touch delivery, including icon centers and target padding.
            store.presentSettings(surface)
            host.view.layoutIfNeeded()
            await fulfillment(of: [appeared, measured], timeout: 5)
            XCTAssertEqual(store.popup, surface)
            let frame = try XCTUnwrap(store.uiPopupFrames[surface])
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertGreaterThan(frame.minX, 0, "Measure the translated panel, not the layout wrapper")
            XCTAssertTrue(window.bounds.contains(frame))
            XCTAssertGreaterThanOrEqual(frame.minY, anchor.maxY)
            XCTAssertLessThan(frame.minY - anchor.maxY, 48)
            XCTAssertGreaterThanOrEqual(anchor.midX, frame.minX - 24)
            XCTAssertLessThanOrEqual(anchor.midX, frame.maxX + 24)
            if surface == .tempo {
                // Widen the preceding key capsule while this popup stays open.
                // Compare independent measured deltas, never the layout solver.
                let movedAnchor = expectation(description: "Tempo anchor moved with key label")
                let movedPanel = expectation(description: "Open tempo panel followed its anchor")
                var receivedMovedAnchor = false
                var receivedMovedPanel = false
                store.uiEventObserver = { event in
                    if event.hasPrefix("anchors.root"),
                       let updated = store.uiAnchorFrames["root"]?[surface],
                       updated.minX > anchor.minX + 1, !receivedMovedAnchor {
                        receivedMovedAnchor = true
                        movedAnchor.fulfill()
                    }
                    if event.hasPrefix("popup.geometry.\(surface.rawValue)"),
                       let updated = store.uiPopupFrames[surface],
                       updated.minX > frame.minX + 1, !receivedMovedPanel {
                        receivedMovedPanel = true
                        movedPanel.fulfill()
                    }
                }
                store.setKey(tonic: 1, mode: store.key.mode)
                host.view.layoutIfNeeded()
                await fulfillment(of: [movedAnchor, movedPanel], timeout: 5)
                let updatedAnchor = try XCTUnwrap(store.uiAnchorFrames["root"]?[surface])
                let updatedFrame = try XCTUnwrap(store.uiPopupFrames[surface])
                XCTAssertEqual(store.popup, surface)
                XCTAssertGreaterThan(updatedFrame.minX - frame.minX, 1)
                XCTAssertEqual(updatedFrame.minX - frame.minX,
                               updatedAnchor.minX - anchor.minX, accuracy: 1)
                XCTAssertEqual(updatedFrame.minY, frame.minY, accuracy: 1)
                XCTAssertTrue(window.bounds.contains(updatedFrame))
            }
            let disappeared = expectation(description: "Production popup removed: \(surface)")
            store.uiEventObserver = { event in
                if event == "popup.disappear.\(surface.rawValue)" { disappeared.fulfill() }
            }
            store.popup = nil
            await fulfillment(of: [disappeared], timeout: 5)
        }
    }

    @MainActor
    func testHostedSettingsPresentedBeforeFirstAnchorPassRenderEverySurface() async throws {
        // Complement the unchanged late-presentation regression above: this
        // ordering initially has a popup but no preferences. Both orders must
        // converge without another action or an unrelated store mutation.
        for surface in [EditorPopup.appSettings, .projectSettings, .keyScale, .tempo] {
            let store = try makeStore(uiDiagnosticsEnabled: true)
            let host = UIHostingController(rootView: CodaCanvas(store: store))
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let previousKeyWindow = scene?.windows.first { $0.isKeyWindow }
            let window = scene.map { UIWindow(windowScene: $0) }
                ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 1366, height: 1024))
            let anchors = expectation(description: "Initial anchors: \(surface)")
            let appeared = expectation(description: "Initially requested popup appeared: \(surface)")
            let measured = expectation(description: "Initially requested popup laid out: \(surface)")
            var receivedAnchors = false
            var receivedGeometry = false
            store.uiEventObserver = { event in
                if event.hasPrefix("anchors.root"), store.uiAnchorFrames["root"]?.count == 4, !receivedAnchors {
                    receivedAnchors = true
                    anchors.fulfill()
                }
                if event == "popup.appear.\(surface.rawValue)" { appeared.fulfill() }
                if event.hasPrefix("popup.geometry.\(surface.rawValue)"), !receivedGeometry {
                    receivedGeometry = true
                    measured.fulfill()
                }
            }
            defer {
                store.uiEventObserver = nil
                window.isHidden = true
                window.rootViewController = nil
                previousKeyWindow?.makeKey()
                store.session?.suspend()
            }
            store.presentSettings(surface)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            await fulfillment(of: [anchors, appeared, measured], timeout: 5)
            XCTAssertEqual(store.popup, surface)
            let anchor = try XCTUnwrap(store.uiAnchorFrames["root"]?[surface])
            let frame = try XCTUnwrap(store.uiPopupFrames[surface])
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertGreaterThan(frame.minX, 0, "Measure the translated panel, not the layout wrapper")
            XCTAssertTrue(window.bounds.contains(frame))
            XCTAssertGreaterThanOrEqual(frame.minY, anchor.maxY)
            XCTAssertLessThan(frame.minY - anchor.maxY, 48)
            XCTAssertGreaterThanOrEqual(anchor.midX, frame.minX - 24)
            XCTAssertLessThanOrEqual(anchor.midX, frame.maxX + 24)
        }
    }

    @MainActor
    func testRenderedCurvedPillsMatchHitTestingAcrossTheirWidthCapsAndScale() {
        for direction in [-Double.pi, -.pi / 3, .pi / 2] {
            for count in [2, 3, 4] {
                let radius = 132.0
                let thickness = 48.0
                for scale in [0.8, 0.9, 1.0] {
                    let bounds = CGRect(x: 0, y: 0, width: 312 * scale, height: 312 * scale)
                    for slot in 0..<count {
                        let path = RingSlotShape(count: count, index: slot, radius: radius,
                            thickness: thickness, direction: direction, scale: scale).path(in: bounds)
                        for degree in 0..<360 {
                            let angle = Double(degree) * .pi / 180 + 0.001
                            for offset in [-25.0, -17, 0, 17, 25] {
                                let local = CGPoint(x: cos(angle) * (radius + offset), y: sin(angle) * (radius + offset))
                                let point = CGPoint(x: bounds.midX + local.x * scale, y: bounds.midY + local.y * scale)
                                XCTAssertEqual(path.contains(point),
                                    RadialGeometry.slot(at: local, count: count, radius: radius,
                                        thickness: thickness, direction: direction) == slot)
                            }
                        }
                        XCTAssertFalse(path.contains(CGPoint(x: bounds.midX, y: bounds.midY)))
                    }
                }
            }
        }
    }

    @MainActor
    func testProductionHoverUsesRoundedPillsAndCancelsOnExposedBackingInEveryMode() throws {
        let store = try makeStore()
        let session = try XCTUnwrap(store.session)
        defer { store.closeRadial(); session.suspend() }
        let original = session.editor.progression
        store.openSqueeze(at: CGPoint(x: 100, y: 100))
        for mode in [RadialMode.primary, .roots, .all] {
            if mode == .roots { store.pencilTouchEnded(at: try point(store, ring: .inner, slot: 0)) }
            if mode == .all { store.pencilTouchEnded(at: try point(store, ring: .roots, slot: 0)) }
            XCTAssertEqual(store.radial?.mode, mode)
            assertRenderedRadialClearsChrome(store)
            let state = try XCTUnwrap(store.radial)
            for (ring, labels, radius, thickness) in store.radialRings() {
                let pill = RadialGeometry.pill(slot: 0, count: labels.count, radius: radius,
                    thickness: thickness, direction: state.placement.direction)
                let cap = CGPoint(x: cos(pill.start) * radius + sin(pill.start) * pill.thickness * 0.45,
                                  y: sin(pill.start) * radius - cos(pill.start) * pill.thickness * 0.45)
                store.pencilHover(at: CGPoint(x: state.center.x + cap.x * state.placement.scale,
                    y: state.center.y + cap.y * state.placement.scale), rollAngle: nil)
                XCTAssertEqual(store.radial?.selectedRing, ring)
                XCTAssertEqual(store.radial?.selectedSlot, 0)
                let middle = (pill.start + pill.end) / 2
                store.pencilHover(at: state.placement.point(radius: radius + thickness / 2 - 1,
                    angle: middle), rollAngle: nil)
                XCTAssertNil(store.radial?.selectedRing, "Exposed backing is not an option")
                XCTAssertNil(store.radial?.selectedSlot)
                XCTAssertNil(store.radialPreview)
                XCTAssertEqual(store.radial?.placement, state.placement)
            }
        }
        XCTAssertEqual(session.editor.progression, original, "Hover and swap draft must not commit music")
    }

    @MainActor
    func testRadialSectorBoundsFitAcrossModesAndOrientationFreezesDuringSelection() throws {
        let store = try makeStore()
        defer { store.session?.suspend() }
        for x in [CGFloat(60), 1356] {
            store.setRootSize(CGSize(width: 1366, height: 1024))
            let tip = CGPoint(x: x, y: store.stripTop + 20)
            store.openSqueeze(at: tip)
            XCTAssertEqual(store.radial?.anchor, tip)
            for mode in [RadialMode.primary, .all] {
                if mode == .all { store.pencilTouchEnded(at: try point(store, ring: .outer, slot: 3)) }
                let state = try XCTUnwrap(store.radial)
                assertRenderedRadialClearsChrome(store)
                for (_, labels, radius, thickness) in store.radialRings() {
                    let bounds = RadialGeometry.bounds(direction: state.placement.direction,
                        radius: (radius + thickness / 2) * state.placement.scale,
                        capRadius: thickness / 2 * state.placement.scale)
                        .offsetBy(dx: state.center.x, dy: state.center.y)
                    XCTAssertTrue(CGRect(origin: .zero, size: store.rootSize).contains(bounds))
                    XCTAssertLessThanOrEqual(labels.count, 4)
                }
            }
            let location = try point(store, ring: .major, slot: 0)
            store.pencilTouchBegan(at: location)
            let frozen = store.radial?.placement
            store.pencilTouchMoved(to: location)
            store.setRootSize(CGSize(width: 1194, height: 834))
            XCTAssertEqual(store.radial?.placement, frozen)
            store.pencilTouchCancelled()
        }
    }

    @MainActor
    func testProductionSqueezeAndLeftEdgeScreenshotFanKeepCompletePathsBelowChrome() throws {
        let store = try makeStore()
        defer { store.session?.suspend() }
        for size in [CGSize(width: 1194, height: 834), CGSize(width: 1366, height: 1024),
                     CGSize(width: 1376, height: 1032)] {
            store.setRootSize(size)
            XCTAssertEqual(store.stripTop, 72)
            for tip in [CGPoint(x: 60, y: 72), CGPoint(x: 60, y: 92),
                        CGPoint(x: size.width / 2, y: 100),
                        CGPoint(x: size.width - 10, y: 92), CGPoint(x: size.width - 10, y: 175)] {
                store.openSqueeze(at: tip)
                XCTAssertEqual(store.radial?.anchor, tip)
                assertRenderedRadialClearsChrome(store)
                store.pencilTouchEnded(at: try point(store, ring: .outer, slot: 3))
                XCTAssertEqual(store.radial?.mode, .all)
                assertRenderedRadialClearsChrome(store)
                let state = try XCTUnwrap(store.radial)
                store.pencilHover(at: try point(store, ring: .minor, slot: 0), rollAngle: nil)
                XCTAssertEqual(store.radial?.placement, state.placement)
                XCTAssertEqual(store.radial?.selectedRing, .minor)
                XCTAssertEqual(store.radial?.selectedSlot, 0)
                store.closeRadial()
            }

            // Same anchor/mode as --coda-ui-fixture-radial-edge, still solved
            // through the production layout path. Do not relocate the fixture.
            store.openSqueeze(at: CGPoint(x: 60, y: store.stripTop + 28))
            var fixture = try XCTUnwrap(store.radial)
            fixture.anchor = CGPoint(x: 12, y: store.stripTop + 16)
            for mode in [RadialMode.primary, .all] {
                fixture.mode = mode
                store.radial = fixture
                store.setRootSize(size)
                XCTAssertEqual(store.radial?.anchor, CGPoint(x: 12, y: 88))
                assertRenderedRadialClearsChrome(store)
                let first = try XCTUnwrap(store.radial?.placement)
                store.setRootSize(size)
                XCTAssertEqual(store.radial?.placement, first)
            }
            store.closeRadial()
        }
    }

    @MainActor
    private func assertRenderedRadialClearsChrome(_ store: CodaEditorStore,
                                                file: StaticString = #filePath, line: UInt = #line) {
        guard let state = store.radial else {
            XCTFail("Expected the production radial", file: file, line: line)
            return
        }
        // Use actual SwiftUI arc paths, not RadialGeometry.bounds (the solver's
        // own oracle), including the continuous backing's extended round caps.
        for (_, labels, radius, thickness) in store.radialRings() {
            let scaledRadius = radius * state.placement.scale
            let scaledThickness = thickness * state.placement.scale
            let extent = scaledRadius + scaledThickness / 2
            let rect = CGRect(x: 0, y: 0, width: extent * 2, height: extent * 2)
            let backing = RadialArcShape(arc: RadialGeometry.backing(radius: radius, thickness: thickness,
                direction: state.placement.direction), scale: state.placement.scale).path(in: rect)
            let paths = [backing] + labels.indices.map { slot in
                RingSlotShape(count: labels.count, index: slot, radius: radius,
                    thickness: thickness, direction: state.placement.direction,
                    scale: state.placement.scale).path(in: rect)
            }
            for path in paths {
                let box = path.boundingRect.offsetBy(dx: state.center.x - extent, dy: state.center.y - extent)
                XCTAssertGreaterThanOrEqual(box.minY, 72 - 1e-6, file: file, line: line)
                XCTAssertGreaterThanOrEqual(box.minX, -1e-6, file: file, line: line)
                XCTAssertLessThanOrEqual(box.maxX, store.rootSize.width + 1e-6, file: file, line: line)
                XCTAssertLessThanOrEqual(box.maxY, store.rootSize.height + 1e-6, file: file, line: line)
            }
        }
    }

    @MainActor
    func testAllFamilyRingChoicesDispatchTheirOriginalProductionIdentity() throws {
        let store = try makeStore()
        defer { store.session?.suspend() }
        for (family, ring) in [(ChordFamily.major, RadialRing.major), (.minor, .minor), (.odd, .odd)] {
            for index in store.qualities(for: family).indices {
                store.openSqueeze(at: CGPoint(x: 100, y: 100))
                store.pencilTouchEnded(at: try point(store, ring: .outer, slot: 3))
                let expected = store.qualities(for: family)[index].id
                store.pencilTouchEnded(at: try point(store, ring: ring, slot: index))
                XCTAssertEqual(store.regions.first?.chord.root, 0)
                XCTAssertEqual(store.regions.first?.chord.qualityID, expected)
            }
        }
    }

    @MainActor
    func testEveryRootIsReachableThroughRealPagedSwapWithoutIntermediateEdits() throws {
        for root in 0..<12 {
            let store = try makeStore()
            let session = try XCTUnwrap(store.session)
            defer { session.suspend() }
            let before = session.editor.progression
            store.openSqueeze(at: CGPoint(x: 100, y: 100))
            store.pencilTouchEnded(at: try point(store, ring: .inner, slot: 0))
            let rootPoint = try point(store, ring: .roots, slot: root)
            XCTAssertEqual(session.editor.progression, before, "Paging must never edit music")
            store.pencilTouchEnded(at: rootPoint)
            XCTAssertEqual(session.editor.progression, before, "Choosing a draft root must remain reversible by cancel")
            store.pencilTouchEnded(at: try point(store, ring: .minor, slot: 0))
            XCTAssertEqual(store.regions.first?.chord.root, root)
            try session.undo()
            XCTAssertEqual(session.editor.progression, before)
        }
    }

    @MainActor
    func testInitialRollRegisterContainsProductionVoicingAndEveryVisiblePitchLabel() throws {
        let store = try makeStore()
        defer { store.session?.suspend() }
        let height = Double(store.rootSize.height - store.rollTop)
        let pitches = store.viewport.visiblePitches(in: height)
        for region in store.regions {
            for pitch in region.pitches { XCTAssertTrue(pitches.contains(pitch)) }
        }
        for (upper, lower) in zip(pitches, pitches.dropFirst()) {
            XCTAssertEqual(upper - lower, 1)
            XCTAssertNotEqual(store.pitchName(upper), store.pitchName(lower))
        }
        XCTAssertEqual(store.rollTop, 176)
    }

    @MainActor
    func testSharedAcrylicCompositesIdenticallyOverContrastingBackdrops() throws {
        let store = try makeStore()
        defer { store.session?.suspend() }
        func pixels(over backdrop: Color) throws -> [UInt8] {
            let renderer = ImageRenderer(content: CodaAcrylic(store: store)
                .frame(width: 32, height: 32).background(backdrop))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.uiImage?.cgImage)
            var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
            try bytes.withUnsafeMutableBytes { storage in
                let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 32, height: 32,
                    bitsPerComponent: 8, bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            return bytes
        }
        let red = try pixels(over: .red)
        XCTAssertEqual(red, try pixels(over: .blue), "Canvas detail/color must never bleed through the material")
        for index in stride(from: 3, to: red.count, by: 4) { XCTAssertEqual(red[index], 255) }
    }

    @MainActor
    func testSettingsPopupBlocksMusicAndCanvasNavigationIngress() throws {
        let store = try makeStore()
        defer { store.session?.suspend() }
        let tip = CGPoint(x: 100, y: 100)
        store.popup = .keyScale
        XCTAssertFalse(store.acceptsPencilLocation(tip))
        XCTAssertFalse(store.beginFingerNavigation(at: CGPoint(x: 500, y: 500)))
        store.openSqueeze(at: tip)
        XCTAssertNil(store.radial)
        XCTAssertEqual(store.regionCount, 1)
    }

    @MainActor
    func testSettingsPresentationCancelsDeleteAndStalePencilOrSqueezeReleasePreservesHistory() throws {
        for popup in [EditorPopup.appSettings, .projectSettings, .keyScale, .tempo] {
            for activeTouch in [false, true] {
                let store = try makeStore()
                let session = try XCTUnwrap(store.session)
                defer { session.suspend() }
                try session.edit([.resize(id: "a", start: 0, length: 15)])
                let redoProgression = session.editor.progression
                try session.undo()
                let original = session.editor.progression
                store.openSqueeze(at: CGPoint(x: 100, y: 100))
                let delete = try point(store, ring: .inner, slot: 3)
                if activeTouch { store.pencilTouchBegan(at: delete) }
                store.pencilHover(at: delete, rollAngle: nil)
                XCTAssertEqual(store.radial?.selectedRing, .inner)
                XCTAssertEqual(store.radial?.selectedSlot, 3)

                store.popup = popup
                XCTAssertNil(store.radial, "Presentation must synchronously cancel the radial")
                XCTAssertFalse(store.hasActivePencilTouch)
                XCTAssertNil(store.holdMenu)
                XCTAssertNil(store.resizeDraft)
                XCTAssertNil(store.radialPreview)
                if activeTouch {
                    store.pencilTouchEnded(at: delete)
                    store.finishSqueeze(at: delete)
                } else {
                    store.finishSqueeze(at: delete)
                    store.pencilTouchEnded(at: delete)
                }
                // Already queued events can also arrive after presentation.
                store.pencilTouchBegan(at: CGPoint(x: 400, y: 100))
                store.pencilTouchMoved(to: delete)
                store.pencilHover(at: delete, rollAngle: nil)
                store.pencilTouchEnded(at: CGPoint(x: 400, y: 100))
                XCTAssertFalse(store.hasActivePencilTouch)
                XCTAssertNil(store.radial)
                XCTAssertEqual(store.popup, popup)
                XCTAssertEqual(store.regionCount, 1)
                XCTAssertEqual(session.editor.progression, original)
                XCTAssertTrue(store.canUndo)
                XCTAssertTrue(store.canRedo)

                // Traverse the real stacks; flags alone cannot detect an extra entry.
                try session.undo()
                XCTAssertTrue(store.regions.isEmpty)
                XCTAssertFalse(store.canUndo)
                try session.redo()
                XCTAssertEqual(session.editor.progression, original)
                try session.redo()
                XCTAssertEqual(session.editor.progression, redoProgression)
                XCTAssertFalse(store.canRedo)
                XCTAssertEqual(store.popup, popup)

                store.setTempo(130)
                store.setKey(tonic: 7, mode: .major)
                XCTAssertEqual(store.tempo, 130)
                XCTAssertEqual(store.key.tonic, 7)
                XCTAssertEqual(store.key.mode, .major)
                store.popup = nil
                store.openSqueeze(at: CGPoint(x: 100, y: 100))
                store.pencilTouchEnded(at: try point(store, ring: .inner, slot: 3))
                XCTAssertEqual(store.regionCount, 0, "Ordinary Pencil Delete must work after dismissal")
                try session.undo()
                XCTAssertEqual(session.editor.progression, redoProgression)
            }
        }
    }

    @MainActor
    func testSettingsPresentationCancelsPendingPreviewAndHoldWork() async throws {
        let store = try makeStore()
        let session = try XCTUnwrap(store.session)
        defer { session.suspend() }
        let original = session.editor.progression
        store.openSqueeze(at: CGPoint(x: 100, y: 100))
        store.pencilHover(at: try point(store, ring: .outer, slot: 0), rollAngle: nil)
        XCTAssertNotNil(store.radialPreview)
        store.popup = .appSettings // Cancel before the queued preview task can run.
        XCTAssertNil(store.radialPreview)
        XCTAssertNil(store.radial)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(session.available, "A cancelled pending preview must not open audio behind settings")
        store.popup = nil
        store.pencilTouchBegan(at: CGPoint(x: 100, y: 100))
        XCTAssertTrue(store.hasActivePencilTouch)
        store.popup = .projectSettings
        XCTAssertFalse(store.hasActivePencilTouch)
        try await Task.sleep(for: .seconds(CodaDesignTokens.Input.holdDuration + 0.05))
        XCTAssertNil(store.holdMenu, "Cancelled hold work cannot present behind settings")
        XCTAssertEqual(store.popup, .projectSettings)
        XCTAssertEqual(session.editor.progression, original)
    }

    @MainActor
    func testSettingsPresentationCancelsResizeHoldAndKnobResetDrafts() throws {
        let store = try makeStore()
        let session = try XCTUnwrap(store.session)
        defer { session.suspend() }
        let original = session.editor.progression
        let edge = CGPoint(x: 56 + store.viewport.x(forStep: 15.8, in: Double(store.contentWidth)), y: 100)
        let end = CGPoint(x: 56 + store.viewport.x(forStep: 23.5, in: Double(store.contentWidth)), y: 100)
        store.pencilTouchBegan(at: edge)
        store.pencilTouchMoved(to: end)
        XCTAssertEqual(store.resizeDraft?.end, 24)
        store.popup = .tempo
        XCTAssertNil(store.resizeDraft)
        store.pencilTouchEnded(at: end)
        XCTAssertEqual(session.editor.progression, original)
        store.popup = nil
        store.holdMenu = HoldMenuState(regionID: "a", origin: CGPoint(x: 100, y: 100), selectedIndex: 2)
        let frame = try XCTUnwrap(store.holdMenuLayout?.frame)
        let delete = CGPoint(x: frame.midX, y: frame.minY + 102)
        store.popup = .keyScale
        XCTAssertNil(store.holdMenu)
        store.pencilTouchEnded(at: delete)
        XCTAssertEqual(session.editor.progression, original)
        store.popup = nil
        store.openKnobReset(.cutoff, at: CGPoint(x: 1200, y: 700))
        store.knobResetSelected = true
        store.popup = .appSettings
        XCTAssertNil(store.knobReset)
        XCTAssertFalse(store.knobResetSelected)
        store.finishSqueeze(at: nil)
        XCTAssertEqual(store.popup, .appSettings)
        XCTAssertEqual(session.editor.progression, original)
    }

    @MainActor
    func testInitialSqueezeReleaseAndStationaryHoverCannotActivateClampedTools() throws {
        let store = try makeStore()
        defer { store.session?.suspend() }
        let before = store.session?.editor.progression
        let tip = CGPoint(x: 100, y: 100)
        store.openSqueeze(at: tip)
        store.pencilHover(at: tip, rollAngle: nil)
        XCTAssertNil(store.radial?.selectedSlot)
        store.finishSqueeze(at: tip)
        XCTAssertNotNil(store.radial, "Opening squeeze release should leave the menu available")
        XCTAssertEqual(store.session?.editor.progression, before)
        store.pencilTouchEnded(at: try point(store, ring: .inner, slot: 3))
        XCTAssertEqual(store.regionCount, 0, "Deliberately lifting on Delete still works")
    }

    @MainActor
    func testDrawerCoversStripAndRollButCannotEditCoveredMusic() throws {
        let store = try makeStore()
        defer { store.session?.suspend() }
        store.drawerOpen = true
        XCTAssertEqual(store.drawerTop, 72)
        XCTAssertEqual(store.synthTop, store.drawerTop + (store.rootSize.height - store.drawerTop) / 2)
        let hiddenBar = CGPoint(x: store.rootSize.width - 30, y: store.stripTop + 20)
        XCTAssertFalse(store.acceptsPencilLocation(hiddenBar))
        store.pencilTouchBegan(at: hiddenBar)
        store.pencilTouchEnded(at: hiddenBar)
        store.openSqueeze(at: hiddenBar)
        XCTAssertNil(store.radial)
        XCTAssertEqual(store.regionCount, 1)
    }

    @MainActor
    func testDraggingChordBodyDoesNotMoveItAndRightEdgeStillResizesOnce() throws {
        let store = try makeStore()
        let session = try XCTUnwrap(store.session)
        defer { session.suspend() }
        let before = session.editor.progression
        let body = CGPoint(x: 100, y: 100)
        store.pencilTouchBegan(at: body)
        store.pencilTouchMoved(to: CGPoint(x: 400, y: 100))
        store.pencilTouchEnded(at: CGPoint(x: 400, y: 100))
        XCTAssertEqual(session.editor.progression, before)
        let width = Double(store.contentWidth)
        let edge = CGPoint(x: 56 + store.viewport.x(forStep: 15.8, in: width), y: 100)
        store.pencilTouchBegan(at: edge)
        for step in [18.5, 20.5, 23.5] {
            store.pencilTouchMoved(to: CGPoint(x: 56 + store.viewport.x(forStep: step, in: width), y: 100))
        }
        store.pencilTouchEnded(at: CGPoint(x: 56 + store.viewport.x(forStep: 23.5, in: width), y: 100))
        XCTAssertEqual(store.regions.first?.start, 0)
        XCTAssertEqual(store.regions.first?.length, 24)
        try session.undo()
        XCTAssertEqual(session.editor.progression, before, "One undo must restore the whole resize drag")
    }

    @MainActor
    func testPencilCoordinatorImplementsTheActualOptionalSqueezeSelector() throws {
        let store = try makeStore()
        defer { store.session?.suspend() }
        let coordinator = PencilInputBridge.Coordinator(store: store)
        XCTAssertTrue(coordinator.responds(to:
            #selector(UIPencilInteractionDelegate.pencilInteraction(_:didReceiveSqueeze:))))
    }

    @MainActor
    private func makeStore(uiDiagnosticsEnabled: Bool = false) throws -> CodaEditorStore {
        let vocabulary = try ChordVocabulary.load(in: Bundle(for: Self.self))
        let session = try MusicSession(vocabulary: vocabulary, offline: true)
        let chord = try Chord(root: 0, qualityID: "minor7")
        try session.edit([.add(ChordRegion(id: "a", chord: chord, start: 0, length: 16,
            pitches: [60, 63, 67, 70]))])
        return CodaEditorStore(session: session, uiDiagnosticsEnabled: uiDiagnosticsEnabled)
    }

    @MainActor
    private func point(_ store: CodaEditorStore, ring: RadialRing, slot: Int) throws -> CGPoint {
        if ring == .roots || ring == .major || ring == .minor || ring == .odd {
            let desiredPage = slot / RadialPage.capacity
            while store.radial?.pages[ring, default: 0] != desiredPage {
                let state = try XCTUnwrap(store.radial)
                let layout = try XCTUnwrap(store.radialRings().first { $0.0 == ring })
                let angle = RadialGeometry.angle(forSlot: layout.1.count - 1, count: layout.1.count,
                    direction: state.placement.direction) + RadialGeometry.sweep / Double(layout.1.count) / 2
                store.pencilTouchEnded(at: state.placement.point(radius: layout.2, angle: angle))
            }
        }
        let state = try XCTUnwrap(store.radial)
        let layout = try XCTUnwrap(store.radialRings().first { $0.0 == ring })
        let localSlot = ring == .inner || ring == .outer ? slot : slot % RadialPage.capacity
        let angle = RadialGeometry.angle(forSlot: localSlot, count: layout.1.count,
            direction: state.placement.direction) + RadialGeometry.sweep / Double(layout.1.count) / 2
        return state.placement.point(radius: layout.2, angle: angle)
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
        let visibleY = store.synthTop + 80
        store.knobFrames = [.cutoff: CGRect(x: x, y: visibleY, width: 42, height: 42)]
        XCTAssertEqual(store.knob(at: CGPoint(x: x + 21, y: visibleY + 21)), .cutoff)
        // The same screen location now contains Reverb after drawer scrolling.
        store.knobFrames = [.cutoff: CGRect(x: x, y: 100, width: 42, height: 42),
                            .reverb: CGRect(x: x, y: visibleY, width: 42, height: 42)]
        let at = CGPoint(x: x + 21, y: visibleY + 21)
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
        store.fxExpanded = true
        store.chromeHidden = true
        XCTAssertNil(store.knob(at: at), "A hidden drawer cannot receive barrel roll or reset")
        store.chromeHidden = false
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
