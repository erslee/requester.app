import XCTest

/// Confirms the app comes up ready to use: no first-run prompt, a real window,
/// and the data-folder commands available for anyone who wants to move it.
final class RequesterUITests: XCTestCase {
    private var app: XCUIApplication!

    private var window: XCUIElement { app.windows.firstMatch }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()

        // Deliberately no REQUESTER_DATA_ROOT: this exercises the default folder.
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 20) {
            app.terminate()
            app.launch()
        }
    }

    override func tearDown() {
        app.terminate()
        app = nil
    }

    @MainActor
    func testOpensStraightIntoTheAppWithoutAskingForAFolder() throws {
        // Assert -- the main window, not a folder picker
        XCTAssertTrue(
            window.buttons["Project"].waitForExistence(timeout: 45),
            "The main window did not open."
        )
        XCTAssertFalse(
            app.staticTexts["Choose a Folder for Your Data"].exists,
            "The app should not ask for a folder on launch."
        )
        XCTAssertFalse(
            app.staticTexts["Could Not Open Your Data"].exists,
            "The app failed to open its data folder."
        )

        // Assert -- a real window, wide enough for all three columns
        XCTAssertTrue(window.exists)
        XCTAssertGreaterThanOrEqual(window.frame.width, 1180)
        XCTAssertTrue(
            window.buttons["Project"].isHittable,
            "The sidebar is outside the window and cannot be clicked."
        )

        // Assert -- the history inspector is showing, as it is by default
        XCTAssertTrue(
            window.staticTexts["History for every request in this project"].exists
                || window.staticTexts["No History"].exists,
            "The history inspector is not visible."
        )

        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Launch"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testFileMenuOffersTheDataFolderCommands() throws {
        // Act
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 20))
        fileMenu.click()

        // Assert
        XCTAssertTrue(
            app.menuItems["Reveal Data Folder in Finder"].waitForExistence(timeout: 5),
            "Reveal Data Folder is missing."
        )
        XCTAssertTrue(app.menuItems["Change Data Folder…"].exists)

        // Already on the default folder, so reverting to it is a no-op
        XCTAssertFalse(app.menuItems["Use Default Data Folder"].isEnabled)
    }
}
