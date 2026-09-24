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
    func testWeightScreenShowsObservedTrendWithoutForecastClaims() throws {
        let app = launch(
            startingAt: "-NomvaStartWeight",
            appearance: "Light",
            additionalArguments: ["-NomvaPerformanceFixture"]
        )
        XCTAssertTrue(app.navigationBars["Weight"].waitForExistence(timeout: 15))
        let saveAlert = app.alerts["Change could not be saved"]
        if saveAlert.exists { saveAlert.buttons["OK"].tap() }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'still an estimate'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'true trend'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'On track for'")).firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "weight-observed-trend-2026-09-23"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testDeniedHealthWriteSavesLocallyWithoutRepeatedAlert() throws {
        let app = launch(
            startingAt: "-NomvaStartWeight",
            appearance: "Dark",
            additionalArguments: ["-NomvaWeightWriteDeniedFixture"]
        )
        XCTAssertTrue(app.navigationBars["Weight"].waitForExistence(timeout: 15))
        let persistenceAlert = app.alerts["Change could not be saved"]
        if persistenceAlert.exists { persistenceAlert.buttons["OK"].tap() }

        app.buttons["Log Weight"].tap()
        let weightField = app.textFields["lbs"]
        XCTAssertTrue(weightField.waitForExistence(timeout: 5))
        weightField.tap()
        weightField.typeText("183.5")
        app.buttons["Save"].tap()

        let permissionAlert = app.alerts["Saved in Nomva"]
        XCTAssertTrue(permissionAlert.waitForExistence(timeout: 10))
        XCTAssertFalse(permissionAlert.buttons["Try Apple Health Again"].exists)
        XCTAssertTrue(permissionAlert.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'saving to Health is paused'")).firstMatch.exists)
        permissionAlert.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Weight"].waitForExistence(timeout: 5))

        app.buttons["Log Weight"].tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Weight"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts["Saved in Nomva"].exists)
    }

    @MainActor
    func testHealthWriteRetryRetriesTheSavedEntry() throws {
        let app = launch(
            startingAt: "-NomvaStartWeight",
            appearance: "Light",
            additionalArguments: ["-NomvaWeightWriteRetryFixture"]
        )
        XCTAssertTrue(app.navigationBars["Weight"].waitForExistence(timeout: 15))
        let persistenceAlert = app.alerts["Change could not be saved"]
        if persistenceAlert.exists { persistenceAlert.buttons["OK"].tap() }

        app.buttons["Log Weight"].tap()
        let weightField = app.textFields["lbs"]
        XCTAssertTrue(weightField.waitForExistence(timeout: 5))
        weightField.tap()
        weightField.typeText("183.5")
        app.buttons["Save"].tap()

        let retryAlert = app.alerts["Saved in Nomva"]
        XCTAssertTrue(retryAlert.waitForExistence(timeout: 10))
        XCTAssertTrue(retryAlert.buttons["Try Apple Health Again"].exists)
        retryAlert.buttons["Try Apple Health Again"].tap()
        XCTAssertTrue(app.navigationBars["Weight"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts["Saved in Nomva"].exists)
    }

    @MainActor
    func testNavigationPerformanceWithHistory() throws {
        let app = launch(
            startingAt: "-NomvaStartLog",
            appearance: "Light",
            additionalArguments: ["-NomvaPerformanceFixture"]
        )
        XCTAssertTrue(app.navigationBars["Today's Log"].waitForExistence(timeout: 15))

        for iteration in 0..<4 {
            recordNavigation(app, tab: "Weight", destination: app.navigationBars["Weight"], iteration: iteration)
            recordNavigation(app, tab: "Settings", destination: app.navigationBars["Settings"], iteration: iteration)
            recordNavigation(app, tab: "AI Chat", destination: app.descendants(matching: .any)["chat.input"].firstMatch, iteration: iteration)
            recordNavigation(app, tab: "Log", destination: app.navigationBars["Today's Log"], iteration: iteration)
        }

        let start = CFAbsoluteTimeGetCurrent()
        app.buttons["Add Food"].tap()
        XCTAssertTrue(app.navigationBars["Add Food"].waitForExistence(timeout: 10))
        print("NOMVA_PERF,Add Food,0,\(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))")

        app.navigationBars["Add Food"].buttons["Cancel"].tap()
        app.tabBars.buttons["Weight"].tap()
        XCTAssertTrue(app.navigationBars["Weight"].waitForExistence(timeout: 10))

        let yearStart = CFAbsoluteTimeGetCurrent()
        app.buttons["1Y"].tap()
        XCTAssertTrue(app.staticTexts["Last Year"].waitForExistence(timeout: 10))
        print("NOMVA_PERF,Weight 1Y,0,\(Int((CFAbsoluteTimeGetCurrent() - yearStart) * 1000))")

        let monthStart = CFAbsoluteTimeGetCurrent()
        app.buttons["30D"].tap()
        XCTAssertTrue(app.staticTexts["Last 30 Days"].waitForExistence(timeout: 10))
        print("NOMVA_PERF,Weight 30D,0,\(Int((CFAbsoluteTimeGetCurrent() - monthStart) * 1000))")

        let weightStart = CFAbsoluteTimeGetCurrent()
        app.buttons["Log Weight"].tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 10))
        print("NOMVA_PERF,Log Weight,0,\(Int((CFAbsoluteTimeGetCurrent() - weightStart) * 1000))")
        app.buttons["Cancel"].tap()

        app.tabBars.buttons["Settings"].tap()
        let goalsStart = CFAbsoluteTimeGetCurrent()
        app.descendants(matching: .any)["settings.goals"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Goals"].waitForExistence(timeout: 10))
        print("NOMVA_PERF,Settings Goals,0,\(Int((CFAbsoluteTimeGetCurrent() - goalsStart) * 1000))")
    }

    @MainActor
    private func recordNavigation(_ app: XCUIApplication, tab: String, destination: XCUIElement, iteration: Int) {
        let alert = app.alerts["Change could not be saved"]
        if alert.exists {
            print("NOMVA_PERF,save alert,\(iteration),1")
            alert.buttons["OK"].tap()
        }
        let start = CFAbsoluteTimeGetCurrent()
        app.tabBars.buttons[tab].tap()
        XCTAssertTrue(destination.waitForExistence(timeout: 10), "\(tab) did not open")
        print("NOMVA_PERF,\(tab),\(iteration),\(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))")
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
