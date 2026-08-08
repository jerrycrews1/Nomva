import XCTest

final class NomvaUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPrimaryTabsAreReachable() throws {
        let app = launch(startingAt: "-NomvaStartLog", appearance: "Light")

        XCTAssertTrue(app.navigationBars["Today's Log"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.tabBars.buttons["AI Chat"].exists)
        XCTAssertTrue(app.tabBars.buttons["Log"].exists)
        XCTAssertTrue(app.tabBars.buttons["Weight"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)

        app.tabBars.buttons["Weight"].tap()
        XCTAssertTrue(app.navigationBars["Weight"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        app.tabBars.buttons["AI Chat"].tap()
        XCTAssertTrue(app.tabBars.buttons["AI Chat"].isSelected)
    }

    @MainActor
    func testGoalsRowHasAFullReliableTapTargetInDarkMode() throws {
        let app = launch(startingAt: "-NomvaStartSettings", appearance: "Dark")

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8))
        let goals = app.descendants(matching: .any)["settings.goals"].firstMatch
        XCTAssertTrue(goals.waitForExistence(timeout: 5))
        goals.tap()
        XCTAssertTrue(app.navigationBars["Goals"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsRemainNavigableAtAccessibilityTextSize() throws {
        let app = launch(
            startingAt: "-NomvaStartSettings",
            appearance: "Light",
            additionalArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
            ]
        )

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.tabBars.buttons["AI Chat"].exists)
        XCTAssertTrue(app.tabBars.buttons["Log"].exists)
        XCTAssertTrue(app.tabBars.buttons["Weight"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)

        let goals = app.descendants(matching: .any)["settings.goals"].firstMatch
        XCTAssertTrue(goals.waitForExistence(timeout: 5))
        goals.tap()
        XCTAssertTrue(app.navigationBars["Goals"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testGarminConnectionControlDoesNotBecomeStranded() throws {
        let app = launch(startingAt: "-NomvaStartSettings", appearance: "Light")

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8))
        let garminRow = app.descendants(matching: .any)["settings.garmin"].firstMatch
        XCTAssertTrue(garminRow.waitForExistence(timeout: 5))
        garminRow.tap()

        XCTAssertTrue(app.navigationBars["Garmin"].waitForExistence(timeout: 5))
        let connectionAction = app.descendants(matching: .any)["garmin.connectionAction"].firstMatch
        XCTAssertTrue(connectionAction.waitForExistence(timeout: 20))
        expectation(
            for: NSPredicate(format: "hittable == true"),
            evaluatedWith: connectionAction
        )
        waitForExpectations(timeout: 25)
    }

    @MainActor
    func testWeightHistorySyncIsDiscoverableFromWeightAndSettings() throws {
        let weightApp = launch(startingAt: "-NomvaStartWeight", appearance: "Light")

        XCTAssertTrue(weightApp.navigationBars["Weight"].waitForExistence(timeout: 8))
        let syncCard = weightApp.descendants(matching: .any)["weight.sync"].firstMatch
        XCTAssertTrue(syncCard.waitForExistence(timeout: 5))
        XCTAssertTrue(syncCard.isHittable)
        syncCard.tap()
        XCTAssertTrue(weightApp.navigationBars["Weight Sync"].waitForExistence(timeout: 5))
        XCTAssertTrue(weightApp.staticTexts["Import Weight History"].exists)
        weightApp.terminate()

        let settingsApp = launch(startingAt: "-NomvaStartSettings", appearance: "Dark")
        XCTAssertTrue(settingsApp.navigationBars["Settings"].waitForExistence(timeout: 8))
        let settingsRow = settingsApp.descendants(matching: .any)["settings.weightSync"].firstMatch
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 5))
        settingsRow.tap()
        XCTAssertTrue(settingsApp.navigationBars["Weight Sync"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func launch(
        startingAt startArgument: String,
        appearance: String,
        additionalArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-NomvaUITesting",
            "-NomvaPowerTestAccess",
            "-onboarding_complete", "YES",
            startArgument,
            "-AppleInterfaceStyle", appearance,
        ] + additionalArguments
        app.launch()
        return app
    }
}
