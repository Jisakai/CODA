import XCTest
import UIKit

final class CodaLaunchTests: XCTestCase {
    @MainActor
    func testLaunchShowsEmptyEditorAndLocksLandscape() {
        let device = XCUIDevice.shared
        defer { device.orientation = .landscapeLeft }
        device.orientation = .landscapeLeft

        let app = XCUIApplication()
        defer { attachDiagnostics(from: app) }
        launchAndDescribe(app)
        XCTAssertTrue(app.buttons["top.play"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["editor.regionCount"].label, "0 chords")
        XCTAssertEqual(app.staticTexts["font.registration"].value as? String, "font-registered")

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(window.frame.width, window.frame.height)
        assertLandscapeContentFrame(in: app)
        device.orientation = .portrait
        XCTAssertTrue(app.buttons["top.play"].exists)
        // AX frames use screen coordinates, which may now be portrait even
        // though the scene remains landscape. Query UIKit's actual geometry.
        assertLandscapeSceneGeometry(in: app)

        app.terminate()
        launchAndDescribe(app, orientation: .portrait)
        assertLandscapeSceneGeometry(in: app)
        device.orientation = .landscapeLeft
        // The scene geometry readout is the lock invariant. After a
        // portrait-launched app, XCTest can retain portrait screen-coordinate
        // frames even while UIKit keeps the scene landscape.
        assertLandscapeSceneGeometry(in: app)
    }

    @MainActor
    func testCaptureNormalizationAppliesOrientationWithoutForcingLandscape() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.preferredRange = .standard
        let source = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 3), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1.5))
            UIColor.green.setFill()
            context.fill(CGRect(x: 1, y: 0, width: 1, height: 1.5))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 1.5, width: 1, height: 1.5))
            UIColor.white.setFill()
            context.fill(CGRect(x: 1, y: 1.5, width: 1, height: 1.5))
        }
        let raw = try XCTUnwrap(source.cgImage)
        let tagged = UIImage(cgImage: raw, scale: 2, orientation: .left) // EXIF 8, not UIImage rawValue 8.
        let upright = try uprightCaptureImage(tagged)
        XCTAssertEqual(upright.imageOrientation, .up)
        XCTAssertEqual(upright.scale, 2)
        XCTAssertEqual(upright.size, CGSize(width: 3, height: 2))
        let png = try XCTUnwrap(upright.pngData())
        let decoded = try XCTUnwrap(UIImage(data: png))
        XCTAssertEqual(decoded.imageOrientation, .up)
        let bitmap = try XCTUnwrap(decoded.cgImage)
        XCTAssertEqual(bitmap.width, 6)
        XCTAssertEqual(bitmap.height, 4)
        // CCW rotation must move actual pixels, not just strip the EXIF tag.
        let corners = [(0, 0), (5, 0), (0, 3), (5, 3)]
        let expected: [[UInt8]] = [[0, 255, 0], [255, 255, 255], [255, 0, 0], [0, 0, 255]]
        for (index, point) in corners.enumerated() {
            let pixel = try XCTUnwrap(bitmap.cropping(to: CGRect(x: CGFloat(point.0), y: CGFloat(point.1), width: 1, height: 1)))
            var rgba = [UInt8](repeating: 0, count: 4)
            try rgba.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            XCTAssertEqual(Array(rgba.prefix(3)), expected[index])
        }
        let portrait = try uprightCaptureImage(source)
        XCTAssertEqual(portrait.size, CGSize(width: 2, height: 3))
        XCTAssertEqual(portrait.cgImage?.width, 4)
        XCTAssertEqual(portrait.cgImage?.height, 6) // A genuinely portrait capture must stay portrait and fail review validation.
    }

    @MainActor
    func testEmptyEditorScreenshotAttachment() {
        let app = XCUIApplication()
        defer { attachDiagnostics(from: app) }
        launchAndDescribe(app)
        XCTAssertTrue(app.buttons["top.play"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["editor.regionCount"].label, "0 chords")
        attachScreenshot(named: "M1-empty-editor", from: app)
    }

    @MainActor
    func testFourBarSeededFixtureScreenshotAttachment() throws {
        let app = XCUIApplication()
        defer { attachDiagnostics(from: app) }
        app.launchArguments = ["--coda-ui-fixture-four-bar"]
        launchAndDescribe(app)
        XCTAssertTrue(app.buttons["top.play"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["editor.regionCount"].label, "4 chords")
        attachScreenshot(named: "M1-four-bar-fixture", from: app)
        app.terminate()
        app.launchArguments = ["--coda-ui-fixture-four-bar", "--coda-ui-fixture-pattern"]
        launchAndDescribe(app)
        // Keep the named review image even if a later hit-target assertion fails.
        attachScreenshot(named: "M1b-pattern-overlay", from: app)
        let topBar = app.descendants(matching: .any).matching(identifier: "editor.topBar").firstMatch
        XCTAssertTrue(topBar.waitForExistence(timeout: 10))
        let controls = topBar.descendants(matching: .any).matching(identifier: "pattern.controls").firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 10))
        XCTAssertEqual(topBar.descendants(matching: .any)
            .matching(identifier: "pattern.controls").count, 1)
        let humanize = controls.buttons["pattern.humanize"]
        let swing = controls.descendants(matching: .any)
            .matching(identifier: "pattern.swing").firstMatch
        XCTAssertTrue(humanize.waitForExistence(timeout: 5))
        XCTAssertTrue(swing.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        var state = try window.snapshot()
        // Geometry and content share one cached tree until real input mutates the UI.
        let diagnosticIDs = ["editor.topBar", "pattern.controls", "pattern.humanize", "pattern.swing",
                             "pattern.overlay", "editor.regionCount", "editor.undoState", "editor.redoState"]
        let frames = diagnosticIDs.map { identifier in
            guard let node = cachedDescendant(identifier, in: state) else { return "\(identifier): absent" }
            return "\(identifier): type=\(node.elementType.rawValue) frame=\(node.frame) label=\(node.label) value=\(String(describing: node.value))"
        }.joined(separator: "\n")
        var diagnosticReports = ["""
        Pattern controls before hit assertions; window=\(state.frame)
        Humanize isHittable=\(humanize.isHittable); Swing isHittable=\(swing.isHittable)
        \(frames)
        """]
        // One allowlisted attachment, including cached pre-input and post-drag
        // evidence. Defer also keeps the report if an unwrap below throws.
        defer {
            let diagnostics = XCTAttachment(string: diagnosticReports.joined(separator: "\n\n"))
            diagnostics.name = "M1b-pattern-controls-AX-before-assertion.txt"
            diagnostics.lifetime = .keepAlways
            add(diagnostics)
        }
        XCTAssertTrue(humanize.isHittable)
        XCTAssertTrue(swing.isHittable)
        // accessibilityHidden describes system accessibility participation;
        // XCTest's descendant snapshot may still retain a layout-only node.
        let overlay = app.descendants(matching: .any).matching(identifier: "pattern.overlay").firstMatch
        let overlayHittable = overlay.isHittable
        diagnosticReports.append("Decorative overlay isHittable=\(overlayHittable)")
        XCTAssertFalse(overlayHittable, "Decorative paint must not be an AX hit target")
        if let paint = cachedDescendant("pattern.overlay", in: state) {
            XCTAssertEqual(paint.elementType, .other)
            XCTAssertTrue(paint.label.isEmpty, "Decorative paint must have no spoken label")
            XCTAssertNil(paint.value, "Decorative paint must expose no control value")
            XCTAssertTrue(paint.children.isEmpty, "Decorative paint must expose no child controls")
        }
        let topBarFrame = try XCTUnwrap(cachedDescendant("editor.topBar", in: state)).frame
        let controlsFrame = try XCTUnwrap(cachedDescendant("pattern.controls", in: state)).frame
        XCTAssertGreaterThanOrEqual(controlsFrame.minX, topBarFrame.midX)
        XCTAssertLessThanOrEqual(topBarFrame.maxX - controlsFrame.maxX, 20)
        XCTAssertGreaterThanOrEqual(controlsFrame.minY, topBarFrame.minY)
        XCTAssertLessThanOrEqual(controlsFrame.maxY, topBarFrame.maxY)
        let activeLayer = try XCTUnwrap(cachedDescendant("top.activeLayer", in: state))
        XCTAssertLessThanOrEqual(activeLayer.frame.maxX, controlsFrame.minX)
        for identifier in ["top.loop", "top.play", "top.chordMute", "top.activeLayer"] {
            let normalControl = try XCTUnwrap(cachedDescendant(identifier, in: state),
                                            "Expected \(identifier) in the top bar")
            XCTAssertFalse(controlsFrame.intersects(normalControl.frame),
                           "Pattern controls must not cover \(identifier)")
        }
        for identifier in ["pattern.done", "pattern.preset", "pattern.spread"] {
            XCTAssertNil(cachedDescendant(identifier, in: state), "Unexpected pattern control \(identifier)")
        }

        let retainedIDs = ["editor.regionCount", "editor.undoState", "editor.redoState"]
            + stride(from: 0, to: 64, by: 16).map { "music.chord.fixture-\($0)" }
        func musicState(in snapshot: XCUIElementSnapshot) throws -> [String] {
            try retainedIDs.map { identifier in
                let node = try XCTUnwrap(cachedDescendant(identifier, in: snapshot))
                return "\(node.identifier)|\(node.label)|\(String(describing: node.value))"
            }
        }
        let retainedMusic = try musicState(in: state)
        XCTAssertEqual(cachedDescendant("editor.regionCount", in: state)?.label, "4 chords")
        XCTAssertEqual(cachedDescendant("pattern.humanize", in: state)?.value as? String, "Tight")
        XCTAssertEqual(cachedDescendant("pattern.swing", in: state)?.value as? String, "0 percent")
        let origin = window.coordinate(withNormalizedOffset: .zero)
        for (offset, expected) in [(CGVector(dx: 0.5, dy: 0.5), "Loose"),
                                   (CGVector(dx: 0.125, dy: 0.5), "Tight")] {
            let frame = try XCTUnwrap(cachedDescendant("pattern.humanize", in: state)).frame
            // Absolute coordinate input also exercises the capsule's left padding,
            // independently of XCTest's automatic element hit-point selection.
            origin.withOffset(CGVector(dx: frame.minX - state.frame.minX + frame.width * offset.dx,
                                       dy: frame.minY - state.frame.minY + frame.height * offset.dy)).tap()
            state = try window.snapshot()
            XCTAssertEqual(cachedDescendant("pattern.humanize", in: state)?.value as? String, expected)
            XCTAssertEqual(cachedDescendant("pattern.swing", in: state)?.value as? String, "0 percent")
            XCTAssertEqual(try musicState(in: state), retainedMusic)
        }
        let swingFrame = try XCTUnwrap(cachedDescendant("pattern.swing", in: state)).frame
        let eventsBeforeSwing = cachedDescendant("editor.uiDiagnostics", in: state)?.value as? String
        diagnosticReports.append("Production UI events before Swing (newest first): \(eventsBeforeSwing ?? "missing")")
        let start = CGPoint(x: swingFrame.midX, y: swingFrame.midY)
        let end = CGPoint(x: start.x, y: start.y - 16)
        XCTAssertTrue(state.frame.contains(start) && state.frame.contains(end), "Keep both finger endpoints on-screen")
        XCTAssertTrue(swingFrame.contains(start) && swingFrame.contains(end))
        origin.withOffset(CGVector(dx: start.x - state.frame.minX, dy: start.y - state.frame.minY))
            .press(forDuration: 0.1, thenDragTo:
                origin.withOffset(CGVector(dx: end.x - state.frame.minX, dy: end.y - state.frame.minY)))
        state = try window.snapshot()
        let firstSwingEvents = cachedDescendant("editor.uiDiagnostics", in: state)?.value as? String
        diagnosticReports.append("""
        After original short Swing drag \(start)->\(end):
        Swing=\(String(describing: cachedDescendant("pattern.swing", in: state)?.value))
        Production UI events (cached): \(String(describing: cachedDescendant("editor.uiDiagnostics", in: state)?.value))
        """)
        let swingValue = try XCTUnwrap(cachedDescendant("pattern.swing", in: state)?.value as? String)
        let percent = try XCTUnwrap(Int(swingValue.components(separatedBy: " ")[0]))
        XCTAssertGreaterThan(percent, 0, "Finger lift must commit Swing through the production gesture")
        XCTAssertLessThanOrEqual(percent, 100)
        XCTAssertEqual(cachedDescendant("pattern.humanize", in: state)?.value as? String, "Tight")
        XCTAssertEqual(try musicState(in: state), retainedMusic)
        XCTAssertNotNil(firstSwingEvents)
        XCTAssertNotEqual(firstSwingEvents, eventsBeforeSwing, "Cached diagnostics must advance for the actual short drag")
        XCTAssertLessThanOrEqual(firstSwingEvents?.utf16.count ?? Int.max, 480)
        XCTAssertTrue(firstSwingEvents?.contains("pattern.swing.") == true,
                      "Latest production ingress/callback evidence must survive the AX snapshot limit")

        let reverseEnd = CGPoint(x: start.x, y: start.y + 16)
        XCTAssertTrue(state.frame.contains(reverseEnd) && swingFrame.contains(reverseEnd))
        origin.withOffset(CGVector(dx: start.x - state.frame.minX, dy: start.y - state.frame.minY))
            .press(forDuration: 0.1, thenDragTo:
                origin.withOffset(CGVector(dx: reverseEnd.x - state.frame.minX, dy: reverseEnd.y - state.frame.minY)))
        state = try window.snapshot()
        let secondSwingEvents = cachedDescendant("editor.uiDiagnostics", in: state)?.value as? String
        diagnosticReports.append("""
        After second, reversed Swing drag \(start)->\(reverseEnd):
        Swing=\(String(describing: cachedDescendant("pattern.swing", in: state)?.value))
        Production UI events (cached): \(String(describing: cachedDescendant("editor.uiDiagnostics", in: state)?.value))
        """)
        let reversedValue = try XCTUnwrap(cachedDescendant("pattern.swing", in: state)?.value as? String)
        let reversedPercent = try XCTUnwrap(Int(reversedValue.components(separatedBy: " ")[0]))
        XCTAssertLessThan(reversedPercent, percent, "A second drag must reverse from the committed baseline")
        XCTAssertGreaterThanOrEqual(reversedPercent, 0)
        XCTAssertEqual(cachedDescendant("pattern.humanize", in: state)?.value as? String, "Tight")
        XCTAssertEqual(try musicState(in: state), retainedMusic)
        XCTAssertNotNil(secondSwingEvents)
        XCTAssertNotEqual(secondSwingEvents, firstSwingEvents, "The reverse drag needs its own fresh evidence")
        XCTAssertLessThanOrEqual(secondSwingEvents?.utf16.count ?? Int.max, 480)
        XCTAssertTrue(secondSwingEvents?.contains("pattern.swing.") == true)
    }

    @MainActor
    func testFingerMusicRegionTapDoesNotEditOrCreateHistory() {
        let app = XCUIApplication()
        defer { attachDiagnostics(from: app) }
        app.launchArguments = ["--coda-ui-fixture-four-bar"]
        launchAndDescribe(app)
        XCTAssertTrue(app.buttons["top.play"].waitForExistence(timeout: 10))
        let emptyBar = app.descendants(matching: .any)["music.empty.5"].firstMatch
        XCTAssertTrue(emptyBar.waitForExistence(timeout: 10))
        let before = app.staticTexts["editor.regionCount"].label
        let historyBefore = app.staticTexts["editor.undoState"].label
        let audioBefore = app.staticTexts["editor.audioAvailability"].label
        emptyBar.tap()
        XCTAssertEqual(app.staticTexts["editor.regionCount"].label, before)
        XCTAssertEqual(app.staticTexts["editor.undoState"].label, historyBefore)
        XCTAssertEqual(app.staticTexts["editor.audioAvailability"].label, audioBefore)

        let chord = app.descendants(matching: .any).matching(identifier: "music.chord.fixture-0").firstMatch
        XCTAssertTrue(chord.exists)
        let selectionBefore = chord.value as? String
        chord.tap()
        XCTAssertEqual(app.staticTexts["editor.regionCount"].label, before)
        XCTAssertEqual(app.staticTexts["editor.undoState"].label, historyBefore)
        XCTAssertEqual(app.staticTexts["editor.audioAvailability"].label, audioBefore)
        XCTAssertEqual(chord.value as? String, selectionBefore)
    }

    @MainActor
    func testDrawerAndAllThreeProductionPresetsAreReachable() {
        let app = XCUIApplication()
        defer { attachDiagnostics(from: app) }
        launchAndDescribe(app)
        XCTAssertTrue(app.buttons["top.synthRack"].waitForExistence(timeout: 10))
        app.buttons["top.synthRack"].tap()
        let rackElement = app.descendants(matching: .any)["editor.bottomSynthRack"].firstMatch
        XCTAssertTrue(rackElement.waitForExistence(timeout: 5))
        let rack = rackElement.frame
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(rack.minX, window.minX, accuracy: 1)
        XCTAssertEqual(rack.maxX, window.maxX, accuracy: 1)
        XCTAssertEqual(rack.maxY, window.maxY, accuracy: 1)
        XCTAssertLessThanOrEqual(rack.height, window.height * 0.50 + 1)
        XCTAssertFalse(app.buttons["top.drawer"].exists)
        for index in 0...2 {
            let preset = app.buttons["drawer.preset.\(index)"]
            XCTAssertTrue(preset.exists)
            preset.tap()
            XCTAssertEqual(preset.value as? String, "selected")
        }
        attachScreenshot(named: "M1-synth-drawer", from: app)
        let synth = app.scrollViews["drawer.synthScroll"].frame
        XCTAssertEqual(synth.minY, rack.minY + 53, accuracy: 2)
        for knob in ["cutoff", "resonance", "shape", "detune", "glide", "chorus", "delay", "reverb"] {
            let control = app.descendants(matching: .any)["drawer.knob.\(knob)"].firstMatch
            revealDrawerElement(control, in: app)
            XCTAssertTrue(control.exists)
            XCTAssertTrue(synth.contains(control.frame), "Synth & Post-FX controls must be directly reachable in the synth rack")
        }
        XCTAssertFalse(app.buttons["drawer.fxMix"].exists, "Extra FX dropdown must stay removed")
        app.buttons["synthRack.close"].tap()
        XCTAssertTrue(rackElement.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["editor.bottomSynthRack"].exists)
    }

    @MainActor
    func testSnapShowsBothFullLabelsInsideOriginalGutterCell() {
        let app = XCUIApplication()
        defer { attachDiagnostics(from: app) }
        launchAndDescribe(app)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let windowFrame = window.frame
        let cellFrame = CGRect(x: windowFrame.minX, y: windowFrame.minY + 52, width: 56, height: 20)
        let division = app.staticTexts["timeline.snap.division"]
        let caption = app.staticTexts["timeline.snap.caption"]
        XCTAssertTrue(division.exists)
        XCTAssertTrue(caption.exists)
        XCTAssertEqual(division.label, "1/16")
        XCTAssertEqual(caption.label, "SNAP")
        // These are the intrinsic, fixed-size rendered Text frames, rather
        // than an AX label on the cell that could conceal truncated content.
        for text in [division, caption] {
            XCTAssertTrue(text.exists)
            XCTAssertGreaterThan(text.frame.width, 0)
            XCTAssertGreaterThan(text.frame.height, 0)
            XCTAssertTrue(cellFrame.contains(text.frame), "Full SNAP text must fit the 56x20 cell")
        }
        XCTAssertLessThanOrEqual(division.frame.maxX, caption.frame.minX)
    }

    @MainActor
    func testKnobValueCapsulesAreOutsideActualDialsAndFingerDragStillWorks() throws {
        let app = XCUIApplication()
        defer { attachDiagnostics(from: app) }
        launchAndDescribe(app)
        XCTAssertTrue(app.buttons["top.synthRack"].waitForExistence(timeout: 10))
        app.buttons["top.synthRack"].tap()
        XCTAssertTrue(app.buttons["drawer.preset.0"].waitForExistence(timeout: 5))
        let knobs = ["wobble", "warmth", "cutoff", "resonance", "shape", "detune", "glide"]
        let drawer = app.descendants(matching: .any)["editor.bottomSynthRack"].firstMatch
        let scroll = app.scrollViews["drawer.synthScroll"]
        var state = try drawer.snapshot()
        func find(_ identifier: String, in node: XCUIElementSnapshot) -> XCUIElementSnapshot? {
            if node.identifier == identifier { return node }
            for child in node.children {
                if let match = find(identifier, in: child) { return match }
            }
            return nil
        }
        func reveal(_ identifier: String) throws -> XCUIElementSnapshot {
            // Geometry/presence share one recursive snapshot until a real UI mutation.
            // Each revealed dial gets one live AX hit test after snapshot-based reveal.
            for attempt in 0...8 {
                let viewport = try XCTUnwrap(find("drawer.synthScroll", in: state))
                let target = find(identifier, in: state)
                if let target, viewport.frame.contains(target.frame) {
                    XCTAssertTrue(viewport.frame.contains(target.frame),
                                  "Drawer control must be fully visible: \(identifier)")
                    return state
                }
                guard attempt < 8 else { break }
                let above = target.map { $0.frame.minY < viewport.frame.minY } ?? false
                // Keep navigation in outer padding, away from the actual dials.
                scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: above ? 0.2 : 0.85))
                    .press(forDuration: 0.05, thenDragTo:
                        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: above ? 0.85 : 0.2)))
                state = try drawer.snapshot()
            }
            XCTFail("Drawer control must be scrollable into view: \(identifier)")
            return state
        }
        for preset in 0...2 {
            _ = try reveal("drawer.preset.\(preset)")
            let button = app.buttons["drawer.preset.\(preset)"]
            XCTAssertTrue(button.isHittable)
            button.tap()
            state = try drawer.snapshot()
            for knob in knobs {
                let snapshot = try reveal("drawer.knob.dial.\(knob)")
                XCTAssertTrue(app.descendants(matching: .any)["drawer.knob.dial.\(knob)"].firstMatch.isHittable)
                let control = find("drawer.knob.\(knob)", in: snapshot)
                let dial = find("drawer.knob.dial.\(knob)", in: snapshot)
                let dot = find("drawer.knob.dot.\(knob)", in: snapshot)
                let readout = find("drawer.knob.readout.\(knob)", in: snapshot)
                XCTAssertNotNil(control, "Missing knob control: \(knob)")
                XCTAssertNotNil(dial, "Missing knob dial: \(knob)")
                XCTAssertNotNil(dot, "Missing center dot: \(knob)")
                XCTAssertNotNil(readout, "Missing knob readout: \(knob)")
                guard let control, let dial, let dot, let readout else { continue }
                let diameter: CGFloat = ["wobble", "warmth"].contains(knob) ? 52 : 42
                XCTAssertEqual(dial.frame.width, diameter, accuracy: 1)
                XCTAssertEqual(dial.frame.height, diameter, accuracy: 1)
                XCTAssertEqual(dot.frame.midX, dial.frame.midX, accuracy: 1)
                XCTAssertEqual(dot.frame.midY, dial.frame.midY, accuracy: 1)
                XCTAssertGreaterThan(readout.frame.width, 0)
                XCTAssertGreaterThanOrEqual(readout.frame.height, 12)
                XCTAssertGreaterThan(readout.frame.minY, dial.frame.maxY)
                XCTAssertFalse(dial.frame.intersects(readout.frame))
                XCTAssertTrue(control.frame.contains(readout.frame))
                XCTAssertTrue((control.value as? String ?? "").hasPrefix("\(readout.label) percent;"))
            }
        }
        let dial = app.descendants(matching: .any)["drawer.knob.dial.cutoff"].firstMatch
        _ = try reveal("drawer.knob.dial.cutoff")
        XCTAssertTrue(dial.isHittable)
        let readout = app.staticTexts["drawer.knob.readout.cutoff"]
        let before = readout.label
        let center = dial.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 0, dy: -20)))
        XCTAssertNotEqual(readout.label, before, "The original dial target must still change the production value")
    }

    @MainActor
    func testChordMuteCenterAndPaddingRemainTappableInBothStates() {
        let app = XCUIApplication()
        defer { attachDiagnostics(from: app) }
        app.launchArguments = ["--coda-ui-fixture-four-bar"]
        launchAndDescribe(app)
        let mute = app.buttons["top.chordMute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 10))
        XCTAssertEqual(mute.value as? String, "sounding")
        XCTAssertEqual(mute.frame.width, 28, accuracy: 1)
        XCTAssertEqual(mute.frame.height, 32, accuracy: 1)

        // Coordinate taps exercise SwiftUI hit testing and the installed
        // UIKit recognizers. AX activation or direct store calls bypass this seam.
        // Padding points are inside the 32pt target but outside the 14pt glyph.
        for point in [CGVector(dx: 0.5, dy: 0.5),
                      CGVector(dx: 0.125, dy: 0.5),
                      CGVector(dx: 0.5, dy: 0.875)] {
            for expected in ["muted", "sounding"] {
                let frame = mute.frame
                let location = CGPoint(x: frame.minX + frame.width * point.dx,
                                       y: frame.minY + frame.height * point.dy)
                print("M1 mute tap before: value=\(mute.value ?? "nil") frame=\(frame) hittable=\(mute.isHittable) point=\(location)")
                XCTAssertTrue(mute.isHittable)
                mute.coordinate(withNormalizedOffset: point).tap()
                print("M1 mute tap after: \(mute.debugDescription)")
                XCTAssertEqual(mute.value as? String, expected)
            }
        }
    }

    @MainActor
    func testActualSessionPlayPauseAndChordMuteControls() {
        let app = XCUIApplication()
        defer { attachDiagnostics(from: app) }
        app.launchArguments = ["--coda-ui-fixture-four-bar"]
        launchAndDescribe(app)
        let play = app.buttons["top.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        let mute = app.buttons["top.chordMute"]
        let initialMute = mute.value as? String
        print("M1 default mute first tap: frame=\(mute.frame) hittable=\(mute.isHittable) value=\(initialMute ?? "nil")")
        mute.tap()
        XCTAssertNotEqual(mute.value as? String, initialMute)
        print("M1 default mute restore tap: frame=\(mute.frame) hittable=\(mute.isHittable) value=\(mute.value ?? "nil")")
        mute.tap()
        let restoredMute = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", initialMute ?? ""), object: mute)
        let restoreResult = XCTWaiter.wait(for: [restoredMute], timeout: 2)
        if restoreResult != .completed {
            attachControlFailure(from: app, name: "M1-mute-restore",
                                 report: "Initial mute: \(initialMute ?? "nil")\nCurrent: \(mute.debugDescription)")
        }
        XCTAssertEqual(restoreResult, .completed)

        for index in 0...2 {
            let synthToggle = app.buttons["top.synthRack"]
            let preset = app.buttons["drawer.preset.\(index)"]
            synthToggle.tap()
            if !preset.waitForExistence(timeout: 2) {
                synthToggle.tap()
            }
            XCTAssertTrue(preset.waitForExistence(timeout: 5))
            preset.tap()
            app.buttons["synthRack.close"].tap()
            XCTAssertTrue(app.buttons["top.synthRack"].waitForExistence(timeout: 5))
            play.tap()
            XCTAssertEqual(play.value as? String, "playing")
            XCTAssertEqual(app.staticTexts["editor.audioAvailability"].label, "available")
            play.tap()
            XCTAssertEqual(play.value as? String, "paused")
        }
    }

    @MainActor
    func testPrimaryRadialScreenshotFixture() {
        let app = XCUIApplication()
        defer { attachDiagnostics(from: app) }
        app.launchArguments = ["--coda-ui-fixture-four-bar", "--coda-ui-fixture-radial-primary"]
        launchAndDescribe(app)
        XCTAssertTrue(app.buttons["top.play"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["radial.menu.primary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["radial.option.inner.0"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["radial.option.outer.3"].exists)
        attachScreenshot(named: "M1-radial-primary-fixture", from: app)

        // Relaunch the real production view with seven DEBUG-only root labels;
        // paging and production action counts stay unchanged.
        app.terminate()
        app.launchArguments = ["--coda-ui-fixture-four-bar", "--coda-ui-fixture-radial-seven"]
        launchAndDescribe(app)
        XCTAssertTrue(app.buttons["top.play"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["radial.menu.roots"].waitForExistence(timeout: 5))
        for slot in 0..<7 {
            let option = app.descendants(matching: .any)["radial.option.roots.\(slot)"]
            XCTAssertTrue(option.exists)
            XCTAssertEqual(option.frame.width, option.frame.height, accuracy: 0.5)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(option.frame))
        }
        XCTAssertFalse(app.descendants(matching: .any)["radial.option.roots.7"].exists)
        attachScreenshot(named: "M1-radial-seven-fixture", from: app)
    }

    @MainActor
    func testEdgePositionedAllQualityRadialScreenshotFixture() {
        let app = XCUIApplication()
        defer { attachDiagnostics(from: app) }
        app.launchArguments = ["--coda-ui-fixture-four-bar", "--coda-ui-fixture-radial-edge"]
        launchAndDescribe(app)
        XCTAssertTrue(app.buttons["top.play"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["radial.menu.all"].waitForExistence(timeout: 5))
        attachScreenshot(named: "M1-radial-edge-fixture", from: app)
    }

    @MainActor
    func testSettingsIconCenterAndPaddingPresentProductionPopups() {
        let app = XCUIApplication()
        defer { attachDiagnostics(from: app) }
        launchAndDescribe(app)
        for surface in ["appSettings", "layers"] {
            let control = app.buttons["top.\(surface)"]
            XCTAssertTrue(control.exists)
            if surface == "appSettings" {
                XCTAssertEqual(control.frame.width, 32, accuracy: 1)
                XCTAssertEqual(control.frame.height, 32, accuracy: 1)
            } else {
                XCTAssertGreaterThanOrEqual(control.frame.width, 26)
                XCTAssertGreaterThanOrEqual(control.frame.height, 28)
            }
            for (context, point) in [("coordinate-center", CGVector(dx: 0.5, dy: 0.5)),
                                     ("coordinate-left-padding", CGVector(dx: 0.125, dy: 0.5)),
                                     ("coordinate-bottom-padding", CGVector(dx: 0.5, dy: 0.875))] {
                XCTAssertTrue(control.isHittable)
                control.coordinate(withNormalizedOffset: point).tap()
                let popup = app.descendants(matching: .any)["settings.popup.\(surface)"].firstMatch
                let appeared = popup.waitForExistence(timeout: 5)
                if !appeared {
                    attachSettingsPopupDiagnostics(from: app, surface: surface, context: context,
                                                   expectedChild: "popup after coordinate tap \(point)", popupAppeared: appeared)
                }
                XCTAssertTrue(appeared, "One tap at \(point) must present \(surface)")
                app.buttons["top.play"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                XCTAssertFalse(popup.exists)
            }
        }
    }

    @MainActor
    func testEverySettingsPopupStaysNearItsOwnInvokingControl() throws {
        let app = XCUIApplication()
        // Retain the final screen capture without resolving live AX queries
        // from defer after a timeout. Cached per-state reports are added below.
        defer {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "M1-diagnostic-testEverySettingsPopupStaysNearItsOwnInvokingControl.png"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        launchAndDescribe(app)
        XCTAssertTrue(app.buttons["top.play"].waitForExistence(timeout: 10))
        var state = try app.windows.firstMatch.snapshot()
        let window = state.frame
        for (controlID, surface, childID) in [("top.appSettings", "appSettings", "settings.loopLength"),
                                               ("top.layers", "layers", "layers.add.chords"),
                                               ("top.keyScale", "keyScale", "settings.key.0"),
                                               ("top.tempo", "tempo", "settings.tempoField")] {
            let control = controlID == "top.tempo" ? app.otherElements[controlID].firstMatch : app.buttons[controlID]
            let sourceNode = cachedDescendant(controlID, in: state)
            XCTAssertNotNil(sourceNode, "Expected invoking control \(controlID)")
            let source = try XCTUnwrap(sourceNode).frame
            print("M1 settings tap: id=\(controlID) frame=\(source) hittable=\(control.isHittable)")
            control.tap()
            // Export a screenshot and the last successful AX state BEFORE any
            // popup lookup can stall. The report explicitly labels stale state.
            attachCachedSettingsState(state, surface: surface, context: "invoking-control",
                                      report: "After tap; AX is cached BEFORE tap. Expected child: \(childID)")
            let popup = app.otherElements["settings.popup.\(surface)"].firstMatch
            let popupAppeared = popup.waitForExistence(timeout: 5)
            // One window snapshot per state includes popup children, viewport,
            // and the production event readout. All checks below are local.
            state = try app.windows.firstMatch.snapshot()
            attachCachedSettingsState(state, surface: surface, context: "invoking-control-snapshot",
                                      report: "After popup wait; appeared=\(popupAppeared). Expected child: \(childID)")
            let popupNode = cachedDescendant("settings.popup.\(surface)", in: state)
            XCTAssertTrue(popupAppeared, "Expected a concrete accessibility container for \(surface)")
            XCTAssertNotNil(popupNode, "Expected popup in cached window snapshot")
            let frame = try XCTUnwrap(popupNode).frame
            XCTAssertNotNil(cachedDescendant(childID, in: try XCTUnwrap(popupNode)),
                            "Expected \(surface) to preserve child identifier \(childID)")
            XCTAssertTrue(window.contains(frame), "\(surface) must fit the landscape viewport")
            XCTAssertGreaterThanOrEqual(frame.minY, source.maxY)
            XCTAssertLessThan(frame.minY - source.maxY, 48)
            XCTAssertGreaterThanOrEqual(source.midX, frame.minX - 24)
            XCTAssertLessThanOrEqual(source.midX, frame.maxX + 24)
            app.buttons["top.play"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            state = try app.windows.firstMatch.snapshot()
            XCTAssertNil(cachedDescendant("settings.popup.\(surface)", in: state),
                         "Expected \(surface) dismissal after tapping Play")
        }
    }

    private func cachedDescendant(_ identifier: String, in node: XCUIElementSnapshot) -> XCUIElementSnapshot? {
        if node.identifier == identifier { return node }
        for child in node.children {
            if let match = cachedDescendant(identifier, in: child) { return match }
        }
        return nil
    }

    @MainActor
    private func attachCachedSettingsState(_ state: XCUIElementSnapshot, surface: String,
                                           context: String, report: String) {
        let name = "M1-settings-\(surface)-\(context)"
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "\(name)-before-assertion.png"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // Snapshot values/children are cached; diagnostics never resolve live queries.
        func describe(_ node: XCUIElementSnapshot, depth: Int = 0) -> String {
            let line = "\(String(repeating: " ", count: depth))id=\(node.identifier) type=\(node.elementType.rawValue) frame=\(node.frame) label=\(node.label) value=\(String(describing: node.value))"
            return ([line] + node.children.map { describe($0, depth: depth + 1) }).joined(separator: "\n")
        }
        let events = cachedDescendant("editor.uiDiagnostics", in: state)?.value
        let text = XCTAttachment(string: "\(report)\nProduction UI events (cached): \(String(describing: events))\n\(describe(state))")
        text.name = "\(name)-AX-before-assertion.txt"
        text.lifetime = .keepAlways
        add(text)
    }

    @MainActor
    private func attachSettingsPopupDiagnostics(from app: XCUIApplication, surface: String, context: String,
                                                expectedChild: String, popupAppeared: Bool) {
        attachControlFailure(from: app, name: "M1-settings-\(surface)-\(context)", report: """
        Surface: \(surface)
        Capture context: \(context)
        Popup AX container found: \(popupAppeared)
        Expected child: \(expectedChild)
        """)
    }

    @MainActor
    private func attachControlFailure(from app: XCUIApplication, name: String, report: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "\(name)-before-assertion.png"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let events = app.staticTexts["editor.uiDiagnostics"].value as? String ?? "UI event readout missing"
        let hierarchy = XCTAttachment(string: "\(report)\n\nProduction UI events:\n\(events)\n\n\(app.debugDescription)")
        hierarchy.name = "\(name)-AX-before-assertion.txt"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    @MainActor
    func testKeyboardRowsStayBelowChromeAndFollowSemitoneRegister() {
        let app = XCUIApplication()
        defer { attachDiagnostics(from: app) }
        app.launchArguments = ["--coda-ui-fixture-four-bar"]
        launchAndDescribe(app)
        XCTAssertTrue(app.buttons["top.play"].waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        let rollTop = window.minY + 52 + 20 + 104
        for midi in 65...76 {
            let label = app.staticTexts["roll.pitch.\(midi)"]
            XCTAssertTrue(label.exists, "Every semitone needs a keyboard label")
            XCTAssertGreaterThanOrEqual(label.frame.minY, rollTop)
            XCTAssertEqual(label.frame.midY, rollTop + CGFloat(76 - midi) * 22 + 11, accuracy: 1)
            XCTAssertLessThanOrEqual(label.frame.maxX, window.minX + 56)
        }
        XCTAssertEqual(app.staticTexts["roll.pitch.76"].label, "E5")
        XCTAssertEqual(app.staticTexts["roll.pitch.75"].label, "D\u{266F}5")
        XCTAssertEqual(app.staticTexts["roll.pitch.65"].label, "F4")
        XCTAssertFalse(app.staticTexts["roll.pitch.96"].exists, "Offscreen C labels must not enter the chrome")
        let roll = app.descendants(matching: .any)["editor.pianoRoll"].firstMatch
        XCTAssertEqual(roll.frame.minY, rollTop, accuracy: 1)
        XCTAssertEqual(roll.frame.maxY, window.maxY - 22, accuracy: 2)
    }

    @MainActor
    private func revealDrawerElement(_ element: XCUIElement, in app: XCUIApplication,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let scroll = app.scrollViews["drawer.synthScroll"]
        XCTAssertTrue(scroll.exists, file: file, line: line)
        for _ in 0..<8 {
            let bounds = scroll.frame
            if element.exists && bounds.contains(element.frame) && element.isHittable { return }
            let above = element.exists && element.frame.minY < bounds.minY
            // Drag in the outer padding so navigating does not turn a knob.
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: above ? 0.2 : 0.85))
                .press(forDuration: 0.05, thenDragTo:
                    scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: above ? 0.85 : 0.2)))
        }
        XCTFail("Drawer control must be scrollable into view: \(element.identifier)", file: file, line: line)
    }

    @MainActor
    private func launchAndDescribe(_ app: XCUIApplication,
                                   orientation: UIDeviceOrientation = .landscapeLeft) {
        // Each test owns its initial state. Otherwise the portrait rotation in
        // the lock test (or a cold simulator) can contaminate review captures.
        XCUIDevice.shared.orientation = orientation
        if !app.launchArguments.contains("--coda-ui-geometry") {
            app.launchArguments.append("--coda-ui-geometry")
        }
        app.launch()
        assertLandscapeSceneGeometry(in: app, checkContent: orientation.isLandscape)
        print("M1 initial launch AX tree (\(name)); app state: \(app.state.rawValue)\n\(app.debugDescription)")
    }

    @MainActor
    @discardableResult
    private func assertLandscapeSceneGeometry(in app: XCUIApplication,
                                              checkContent: Bool = false,
                                              file: StaticString = #filePath, line: UInt = #line) -> CGRect {
        do {
            // One remote AX request after launch/orientation synchronization.
            // Never nest remote AX work inside a waiter: its deadline can
            // interrupt the snapshot before otherwise valid geometry returns.
            let state = try app.windows.firstMatch.snapshot()
            let bounds = state.frame
            let readout = cachedDescendant("editor.sceneGeometry", in: state)
            let value = readout?.value as? String
            let fields = value?.split(separator: "|", omittingEmptySubsequences: false) ?? []
            let sizes = fields.dropFirst().compactMap { Double($0) }
            guard fields.count == 7, fields[0] == "landscape",
                  sizes.count == 6, sizes.allSatisfy({ $0.isFinite }),
                  sizes[0] > sizes[1], sizes[1] > 0 else {
                XCTFail("Expected landscape scene/window/host sizes; got \(value ?? "nil")",
                        file: file, line: line)
                return bounds
            }
            // Scene, window and hosting view must agree even when AX screen
            // coordinates remain portrait after a portrait-start lock check.
            XCTAssertTrue(stride(from: 2, to: 6, by: 2).allSatisfy {
                abs(sizes[$0] - sizes[0]) <= 1 && abs(sizes[$0 + 1] - sizes[1]) <= 1
            }, "Expected matching landscape scene/window/host sizes; got \(value ?? "nil")",
               file: file, line: line)
            if checkContent {
                let bar = cachedDescendant("editor.topBar", in: state)?.frame ?? .zero
                XCTAssertTrue(bounds.width > bounds.height && bar.width > bar.height
                    && abs(bar.height - 52) <= 1 && abs(bar.width - bounds.width) <= 1
                    && abs(bar.minX - bounds.minX) <= 1 && abs(bar.minY - bounds.minY) <= 1,
                    "Top bar must span the landscape window horizontally: \(bar), window: \(bounds)",
                    file: file, line: line)
            }
            return bounds
        } catch {
            XCTFail("Unable to snapshot landscape geometry: \(error)", file: file, line: line)
            return .zero
        }
    }

    @MainActor
    @discardableResult
    private func assertLandscapeContentFrame(in app: XCUIApplication,
                                             file: StaticString = #filePath, line: UInt = #line) -> CGRect {
        assertLandscapeSceneGeometry(in: app, checkContent: true, file: file, line: line)
    }

    @MainActor
    private func attachDiagnostics(from app: XCUIApplication) {
        // Registered with defer before launch in every test: capture even when
        // a later assertion or element lookup prevents the review screenshot.
        let testName = name.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .first(where: { $0.hasPrefix("test") }) ?? "unknown"
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "M1-diagnostic-\(testName).png"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("M1 final AX tree (\(name)); app state: \(app.state.rawValue)\n\(app.debugDescription)")
    }

    @MainActor
    private func uprightCaptureImage(_ image: UIImage) throws -> UIImage {
        let raw = try XCTUnwrap(image.cgImage)
        let swapsAxes: Bool
        switch image.imageOrientation {
        case .left, .right, .leftMirrored, .rightMirrored: swapsAxes = true
        default: swapsAxes = false
        }
        let size = CGSize(width: CGFloat(swapsAxes ? raw.height : raw.width) / image.scale,
                          height: CGFloat(swapsAxes ? raw.width : raw.height) / image.scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale // Preserve source resolution, not the test runner's screen scale.
        format.preferredRange = .standard
        // UIImage.draw applies metadata, unlike drawing the raw CGImage. Never
        // rotate merely because width < height: an incorrect portrait must fail.
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    @MainActor
    private func attachScreenshot(named name: String, from app: XCUIApplication) {
        let window = assertLandscapeContentFrame(in: app)
        do {
            // app.screenshot() previously cropped/padded already-oriented pixels
            // while retaining EXIF 8. Capture the full display, then bake its
            // orientation into pixels once; do not normalize the app crop.
            let source = XCUIScreen.main.screenshot().image
            let upright = try uprightCaptureImage(source)
            XCTAssertEqual(upright.imageOrientation, .up)
            XCTAssertGreaterThan(upright.size.width, upright.size.height,
                                 "Review capture must be landscape after applying source metadata")
            let png = try XCTUnwrap(upright.pngData())
            let decoded = try XCTUnwrap(UIImage(data: png))
            let bitmap = try XCTUnwrap(decoded.cgImage)
            XCTAssertEqual(decoded.imageOrientation, .up, "Exported PNG must not need an EXIF rotation")
            XCTAssertGreaterThan(bitmap.width, bitmap.height,
                                 "Exported pixels must span the full landscape screen")
            XCTAssertEqual(CGFloat(bitmap.width), source.size.width * source.scale, accuracy: 1,
                           "Capture must retain the full oriented source pixel extent")
            XCTAssertEqual(CGFloat(bitmap.height), source.size.height * source.scale, accuracy: 1)
            // UIImage.scale belongs to the capture, not necessarily the app's
            // point-to-screen scale. Compare window shape without conflating them.
            XCTAssertEqual(CGFloat(bitmap.width) / CGFloat(bitmap.height),
                           window.width / window.height, accuracy: 0.001,
                           "Capture and actual landscape window must have matching aspect ratios")
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "\(name).png"
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            XCTFail("Unable to normalize full-screen capture: \(error)")
        }
    }
}
