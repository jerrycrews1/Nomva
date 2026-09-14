import XCTest

final class NomvaReliabilityUITests: XCTestCase {
    @MainActor
    func testBottleNutritionSurvivesEditingAndChatCorrection() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-NomvaUITesting", "-NomvaPowerTestAccess", "-onboarding_complete", "YES", "-NomvaBeverageRegression", "-NomvaStartLog"]
        app.launch()
        let foodName = "Gatorade Cool Blue — 12 fl oz (28 oz bottle)"
        let row = app.staticTexts[foodName].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars["Edit Entry"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Total Grams"].exists)
        XCTAssertTrue(app.staticTexts["80.0 kcal"].exists)
        let amount = app.textFields["foodEdit.amount"]
        amount.tap()
        amount.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        else { amount.typeText(XCUIKeyboardKey.delete.rawValue) }
        amount.typeText("2")
        app.buttons["foodEdit.save"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["160.0 kcal"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Total Grams"].exists)
        app.buttons["Cancel"].tap()
        app.tabBars.buttons["AI Chat"].tap()
        let input = app.descendants(matching: .any)["chat.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("I had the whole bottle of Gatorade not just 12 oz")
        app.buttons["Send message"].tap()
        let corrected = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "1 bottle (28 fl oz)", "187 cal")).firstMatch
        XCTAssertTrue(corrected.waitForExistence(timeout: 12))
        app.tabBars.buttons["Log"].tap()
        XCTAssertEqual(app.staticTexts.matching(identifier: foodName).count, 1)
        row.tap()
        XCTAssertTrue(app.staticTexts["186.7 kcal"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Bottle nutrition after saved edit and chat correction"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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
