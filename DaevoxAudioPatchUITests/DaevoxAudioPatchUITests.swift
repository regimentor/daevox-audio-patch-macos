import XCTest

final class DaevoxAudioPatchUITests: XCTestCase {
    @MainActor
    func testNativeNavigationAndDeviceDiscovery() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Prevent startup from restoring saved routes or writing driver configuration.
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Устройства"].firstMatch.exists)
        app.staticTexts["Виртуальные устройства"].firstMatch.click()
        XCTAssertTrue(app.buttons["Создать устройство"].waitForExistence(timeout: 5))
        app.staticTexts["Маршрутизация"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Выберите виртуальное устройство"].waitForExistence(timeout: 5))
        app.staticTexts["Диагностика"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["HAL-драйвер"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "AudioPatch Diagnostics"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate()
    }

    @MainActor
    func testLiveRestoredLaunchDockAndStatusMenu() async throws {
        guard ProcessInfo.processInfo.environment["AUDIOPATCH_LIVE_UI"] == "1" else {
            throw XCTSkip("Opt-in: requires the installed driver, saved enabled route and microphone consent")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        // Intentionally use the NORMAL startup path, including persisted HAL sync and restore.
        app.launchArguments = []
        for _ in 0..<2 {
            app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
            try await Task.sleep(for: .seconds(3)) // cross periodic reconciliation, then actually click
            app.staticTexts["Виртуальные устройства"].firstMatch.click()
            XCTAssertTrue(app.staticTexts["Маршрутизация работает"].firstMatch.waitForExistence(timeout: 10))
            app.staticTexts["Диагностика"].firstMatch.click()
            XCTAssertTrue(app.staticTexts["HAL-драйвер"].waitForExistence(timeout: 5))
            let status = app.statusItems.firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 5), app.debugDescription)
            status.click()
            XCTAssertTrue(app.menuItems["Открыть AudioPatch"].waitForExistence(timeout: 5))
            app.typeKey(.escape, modifierFlags: [])
            status.rightClick()
            XCTAssertTrue(app.menuItems["Открыть AudioPatch"].waitForExistence(timeout: 5))
            app.typeKey(.escape, modifierFlags: [])
            app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
            let dock = XCUIApplication(bundleIdentifier: "com.apple.dock")
            let icons = dock.dockItems.matching(NSPredicate(format: "title CONTAINS[c] %@", "AudioPatch"))
            let icon = icons.element(boundBy: max(0, icons.count - 1))
            XCTAssertTrue(icon.waitForExistence(timeout: 5), dock.debugDescription)
            icon.click()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
            app.terminate()
        }
    }

}
