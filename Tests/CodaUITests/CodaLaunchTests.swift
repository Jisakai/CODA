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
        assertLandscapeContentFrame(in: app)
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
    func testFourBarSeededFixtureScreenshotAttachment() {
        let app = XCUIApplication()
        defer { attachDiagnostics(from: app) }
        app.launchArguments = ["--coda-ui-fixture-four-bar"]
        launchAndDescribe(app)
        XCTAssertTrue(app.buttons["top.play"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["editor.regionCount"].label, "4 chords")
        attachScreenshot(named: "M1-four-bar-fixture", from: app)
    }

    @MainActor
    func testFingerMusicRegionTapDoesNotEditOrCreateHistory() {
        let app = XCUIApplication()
        defer { attachDiagnostics(from: app) }
        app.launchArguments = ["--coda-ui-fixture-four-bar"]
        launchAndDescribe(app)
        XCTAssertTrue(app.buttons["top.play"].waitForExistence(timeout: 10))
        let emptyBar = app.descendants(matching: .any)["music.empty.5"].firstMatch
        XCTAssertTrue(emptyBar.waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.buttons["top.drawer"].waitForExistence(timeout: 10))
        app.buttons["top.drawer"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["editor.synthDrawer"].waitForExistence(timeout: 5))
        let drawer = app.descendants(matching: .any)["editor.synthDrawer"].firstMatch.frame
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(drawer.minY, window.minY + 52 + 20 + 104, accuracy: 1)
        XCTAssertEqual(drawer.maxX, window.maxX, accuracy: 1)
        XCTAssertEqual(drawer.maxY, window.maxY, accuracy: 1)
        for index in 0...2 {
            let preset = app.buttons["drawer.preset.\(index)"]
            XCTAssertTrue(preset.exists)
            preset.tap()
            XCTAssertEqual(preset.value as? String, "selected")
        }
        XCTAssertTrue(app.descendants(matching: .any)["drawer.knob.cutoff"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["drawer.knob.resonance"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["drawer.knob.shape"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["drawer.knob.detune"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["drawer.knob.glide"].exists)
        attachScreenshot(named: "M1-synth-drawer", from: app)
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
        XCTAssertEqual(mute.frame.width, 32, accuracy: 1)
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
        mute.tap()
        XCTAssertNotEqual(mute.value as? String, initialMute)
        mute.tap()
        let restoredMute = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", initialMute ?? ""), object: mute)
        XCTAssertEqual(XCTWaiter.wait(for: [restoredMute], timeout: 2), .completed)

        for index in 0...2 {
            app.buttons["top.drawer"].tap()
            app.buttons["drawer.preset.\(index)"].tap()
            app.buttons["drawer.close"].tap()
            play.tap()
            XCTAssertEqual(play.value as? String, "playing")
            XCTAssertEqual(app.staticTexts["editor.audioAvailability"].label, "available")
            play.tap()
            XCTAssertEqual(play.value as? String, "paused")
        }
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
    private func launchAndDescribe(_ app: XCUIApplication,
                                   orientation: UIDeviceOrientation = .landscapeLeft) {
        // Each test owns its initial state. Otherwise the portrait rotation in
        // the lock test (or a cold simulator) can contaminate review captures.
        XCUIDevice.shared.orientation = orientation
        if !app.launchArguments.contains("--coda-ui-geometry") {
            app.launchArguments.append("--coda-ui-geometry")
        }
        app.launch()
        assertLandscapeSceneGeometry(in: app)
        if orientation.isLandscape { assertLandscapeContentFrame(in: app) }
        print("M1 initial launch AX tree (\(name)); app state: \(app.state.rawValue)\n\(app.debugDescription)")
    }

    @MainActor
    private func assertLandscapeSceneGeometry(in app: XCUIApplication,
                                              file: StaticString = #filePath, line: UInt = #line) {
        let readout = app.staticTexts["editor.sceneGeometry"]
        let validGeometry = NSPredicate { _, _ in
            guard readout.exists, let value = readout.value as? String else { return false }
            let fields = value.split(separator: "|")
            guard fields.count == 7, fields[0] == "landscape" else { return false }
            let sizes = fields.dropFirst().compactMap { Double($0) }
            guard sizes.count == 6, sizes[0] > sizes[1], sizes[1] > 0 else { return false }
            // Scene, window and hosting view must agree: no portrait window
            // underneath a landscape host, or stale host size after rotation.
            return stride(from: 2, to: 6, by: 2).allSatisfy {
                abs(sizes[$0] - sizes[0]) <= 1 && abs(sizes[$0 + 1] - sizes[1]) <= 1
            }
        }
        let ready = XCTNSPredicateExpectation(predicate: validGeometry, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed,
                       "Expected matching landscape scene/window/host sizes; got \(readout.value ?? "nil")",
                       file: file, line: line)
    }

    @MainActor
    private func assertLandscapeContentFrame(in app: XCUIApplication,
                                             file: StaticString = #filePath, line: UInt = #line) {
        let topBar = app.descendants(matching: .any)["editor.topBar"].firstMatch
        let window = app.windows.firstMatch
        let landscapeFrame = NSPredicate { _, _ in
            guard topBar.exists, window.exists else { return false }
            let bar = topBar.frame
            let bounds = window.frame
            return bounds.width > bounds.height && bar.width > bar.height
                && abs(bar.height - 52) <= 1 && abs(bar.width - bounds.width) <= 1
                && abs(bar.minX - bounds.minX) <= 1 && abs(bar.minY - bounds.minY) <= 1
        }
        let ready = XCTNSPredicateExpectation(predicate: landscapeFrame, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed,
                       "Top bar must span the landscape window horizontally: \(topBar.frame), window: \(window.frame)",
                       file: file, line: line)
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
    private func attachScreenshot(named name: String, from app: XCUIApplication) {
        assertLandscapeSceneGeometry(in: app)
        assertLandscapeContentFrame(in: app)
        let screenshot = app.screenshot()
        let screen = XCUIScreen.main.screenshot()
        XCTAssertGreaterThan(screen.image.size.width, screen.image.size.height,
                             "Review capture must start from a landscape screen bitmap")
        XCTAssertEqual(screenshot.image.size, screen.image.size,
                       "App and screen capture extents must agree; avoid portrait cropping/black padding")
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
