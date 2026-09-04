import XCTest

/// The File menu is built by the scene, which does not own the model -- so that
/// the Import command is present and enabled is worth asserting rather than
/// assuming.
final class MenuCommandsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["REQUESTER_DATA_ROOT"] = "uitest-\(UUID().uuidString)"
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
    func testFileMenuOffersImportCollection() throws {
        // Act
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 45))
        fileMenu.click()

        // Assert -- present, enabled, and named without mentioning Postman
        let importItem = app.menuItems["Import Collection…"]
        XCTAssertTrue(importItem.waitForExistence(timeout: 5), "Import Collection is missing.")
        XCTAssertTrue(importItem.isEnabled, "Import Collection should be usable.")

        // Assert -- making and opening projects moved here from the sidebar
        XCTAssertTrue(app.menuItems["New Project"].exists, "New Project is missing.")
        XCTAssertTrue(app.menuItems["New Project"].isEnabled)
        XCTAssertTrue(app.menuItems["Open Project…"].exists, "Open Project is missing.")

        // Assert -- the data-folder command is still there, below it
        XCTAssertTrue(app.menuItems["Reveal Data Folder in Finder"].exists)
    }
}
