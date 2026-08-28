import XCTest

/// Exercises the real UI against a throwaway data folder: make a project from
/// the launcher, add a variable, create a request, and check the editor's tabs
/// and highlighting all render and respond.
final class MainWindowUITests: XCTestCase {
    private var app: XCUIApplication!

    /// The launcher, by title -- with a project window open too, a bare
    /// `app.windows.firstMatch` is ambiguous.
    private var launcher: XCUIElement { app.windows["Requester"] }

    /// The project window, named after the project it holds.
    private func projectWindow(_ name: String) -> XCUIElement { app.windows[name] }

    override func setUpWithError() throws {
        continueAfterFailure = false

        // A bare name, so the app creates a throwaway folder inside its own
        // sandbox container -- this runner is sandboxed too and cannot reach it.
        app = XCUIApplication()
        app.launchEnvironment["REQUESTER_DATA_ROOT"] = "uitest-\(UUID().uuidString)"

        // The very first launch of a freshly built binary intermittently comes
        // up with no window at all; relaunching once clears it.
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
    func testCreatesAProjectAndRequestAndEditsIt() throws {
        // Assert -- an empty folder lands on the launcher, not a picker.
        // A cold Debug launch can be slow, hence the generous wait.
        let newProject = launcher.buttons["New Project"]
        XCTAssertTrue(newProject.waitForExistence(timeout: 45), "The launcher did not open.")
        XCTAssertTrue(launcher.staticTexts["No projects yet."].exists)

        // Act -- a new project opens in its own window, named for the project
        newProject.click()
        let window = projectWindow("Untitled Project")
        XCTAssertTrue(
            window.waitForExistence(timeout: 15),
            "A new project did not open its own window, titled with its name."
        )

        // Assert -- the project's own pane is what a new window lands on
        let newKey = window.textFields["New key"]
        XCTAssertTrue(
            newKey.waitForExistence(timeout: 8), "The project detail view did not appear."
        )

        // Assert -- making projects is no longer a sidebar action
        XCTAssertFalse(
            window.buttons["Project"].exists,
            "The sidebar should no longer offer a New Project button."
        )

        // Act -- add a variable the request can reference
        newKey.click()
        newKey.typeText("host")
        let newValue = window.textFields["New value"]
        newValue.click()
        newValue.typeText("swapi.info")
        newValue.typeText("\r")  // the value field submits the new variable

        // Assert -- it now appears as a manual variable
        XCTAssertTrue(window.staticTexts["host"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["manual"].exists)

        // Act -- create a request in that project
        let requestButton = window.buttons["Request"]
        // Hittability matters on its own: if the window is too narrow for all
        // three columns, the split view overflows and the sidebar lands outside
        // the window, where it exists and is enabled but cannot be clicked.
        XCTAssertTrue(requestButton.isHittable, "The sidebar toolbar is outside the window.")
        requestButton.click()
        let urlField = window.textFields["https://example.com/path?query=value"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 8), "The request editor did not open.")

        // Act -- type a URL that uses the variable
        urlField.click()
        urlField.typeText("https://{{host}}/api/")

        // Assert -- the editor's parts are all present
        XCTAssertTrue(window.buttons["Send"].exists)
        XCTAssertTrue(window.staticTexts["No request sent yet."].exists)

        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Editor"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A project gets one window: asking for the same one again focuses what is
    /// already open rather than opening a duplicate.
    @MainActor
    func testReopeningAProjectFocusesItsExistingWindow() throws {
        // Arrange -- one project, in its window
        let newProject = launcher.buttons["New Project"]
        XCTAssertTrue(newProject.waitForExistence(timeout: 45), "The launcher did not open.")
        newProject.click()

        let window = projectWindow("Untitled Project")
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        let windowCount = app.windows.count

        // Act -- back to the launcher and open the same project again
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Open Project…"].click()
        let row = launcher.buttons["Untitled Project"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The project is not listed as recent.")
        row.click()

        // Assert -- focused, not duplicated
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(
            app.windows.count, windowCount, "Opening the same project made a second window."
        )
    }
}
