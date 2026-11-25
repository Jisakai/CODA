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
    @discardableResult
    private func assertLandscapeContentFrame(in app: XCUIApplication,
                                             file: StaticString = #filePath, line: UInt = #line) -> CGRect {
        let topBar = app.otherElements["editor.topBar"].firstMatch
        let window = app.windows.firstMatch
        var bar = CGRect.zero
        var bounds = CGRect.zero
        var snapshotError = "none"
        let landscapeFrame = NSPredicate { _, _ in
            do {
                // Read each element once per poll, rather than separate exists
                // and frame queries against all AX element types.
                bar = try topBar.snapshot().frame
                bounds = try window.snapshot().frame
                snapshotError = "none"
            } catch {
                snapshotError = String(describing: error)
                return false
            }
            return bounds.width > bounds.height && bar.width > bar.height
                && abs(bar.height - 52) <= 1 && abs(bar.width - bounds.width) <= 1
                && abs(bar.minX - bounds.minX) <= 1 && abs(bar.minY - bounds.minY) <= 1
        }
        let ready = XCTNSPredicateExpectation(predicate: landscapeFrame, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: 10)
        // Never issue fresh AX frame queries while building a failure message:
        // those retries outlived the waiter and the test allowance on CI.
        XCTAssertEqual(result, .completed,
                       "Top bar must span the landscape window horizontally: \(bar), window: \(bounds), snapshot error: \(snapshotError)",
                       file: file, line: line)
        return bounds
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
        assertLandscapeSceneGeometry(in: app)
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
