import XCTest

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
        device.orientation = .portrait
        XCTAssertTrue(app.buttons["top.play"].exists)
        XCTAssertGreaterThan(window.frame.width, window.frame.height,
                             "The editor must remain landscape after a portrait rotation attempt")
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
    private func launchAndDescribe(_ app: XCUIApplication) {
        app.launch()
        print("M1 initial launch AX tree (\(name)); app state: \(app.state.rawValue)\n\(app.debugDescription)")
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
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
