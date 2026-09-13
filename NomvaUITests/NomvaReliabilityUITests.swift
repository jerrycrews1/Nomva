import XCTest

final class NomvaReliabilityUITests: XCTestCase {
    @MainActor
    func testWeightSyncUsesAppleHealthWithoutCloudSetup() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-NomvaUITesting", "-NomvaPowerTestAccess", "-onboarding_complete", "YES"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        let storage = app.buttons["settings.dataStorage"]
        app.swipeUp()
        XCTAssertTrue(storage.waitForExistence(timeout: 5))
        storage.tap()
        XCTAssertTrue(app.staticTexts["Stored on this device"].waitForExistence(timeout: 5))
        app.buttons["Apple Health & Garmin Weigh-ins"].tap()
        XCTAssertTrue(app.staticTexts["Garmin → Apple Health → Nomva"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["Import Garmin History"].exists)
    }

    @MainActor
    func testDatedChatWeightEntryKeepsItsReplyVisibleAndReachesHistory() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-NomvaUITesting", "-NomvaPowerTestAccess", "-onboarding_complete", "YES", "-NomvaStartChat", "-AppleInterfaceStyle", "Light"]
        app.launch()
        let input = app.descendants(matching: .any)["chat.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.tap()
        input.typeText("I weighed 80 kg yesterday")
        app.buttons["Send message"].tap()
        let saved = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Logged 176.4 lb")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Yesterday")).firstMatch.exists)
        app.tabBars.buttons["Weight"].tap()
        XCTAssertTrue(app.navigationBars["Weight"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "176.4")).firstMatch.exists)
    }
}
