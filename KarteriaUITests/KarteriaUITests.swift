import XCTest

final class KarteriaUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-demo"]
        app.launch()
    }

    func testDemoExchangeAndCalibrationAreReachable() throws {
        XCTAssertTrue(app.staticTexts["Karteria"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Review Next"].exists)

        app.buttons["Review Next"].tap()

        XCTAssertTrue(app.navigationBars["Review proof"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Acknowledge a customer concern"].exists)
        XCTAssertTrue(app.staticTexts["Rubric"].exists)
        XCTAssertTrue(app.buttons["Close"].exists)
    }

    func testThreePrimaryTabsAreAvailable() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.buttons["Exchange"].exists)
        XCTAssertTrue(tabBar.buttons["Practice"].exists)
        XCTAssertTrue(tabBar.buttons["Journey"].exists)

        tabBar.buttons["Practice"].tap()
        XCTAssertTrue(app.staticTexts["CURRENT LEVEL"].waitForExistence(timeout: 3))

        tabBar.buttons["Journey"].tap()
        XCTAssertTrue(app.staticTexts["Verified levels"].waitForExistence(timeout: 3))
    }
}
