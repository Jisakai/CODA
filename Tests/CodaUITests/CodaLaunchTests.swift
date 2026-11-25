import XCTest

final class CodaLaunchTests: XCTestCase {
    @MainActor
    func testLaunchDisplaysWordmarkWithFontAndLocksLandscape() {
        let device = XCUIDevice.shared
        defer { device.orientation = .landscapeLeft }
        device.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launch()

        let wordmark = app.staticTexts["coda.wordmark"]
        XCTAssertTrue(wordmark.waitForExistence(timeout: 5))
        XCTAssertEqual(wordmark.value as? String, "font-registered")

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(window.frame.width, window.frame.height, "App should launch in landscape")

        device.orientation = .portrait
        XCTAssertEqual(device.orientation, .portrait, "Portrait rotation should be attempted")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertGreaterThan(
            window.frame.width,
            window.frame.height,
            "App should remain in landscape after a portrait rotation attempt"
        )
    }
}
