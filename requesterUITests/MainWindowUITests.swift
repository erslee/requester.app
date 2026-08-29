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


    /// Brings the launcher up deliberately, rather than assuming it is what the
    /// app came up on.
    ///
    /// Under XCUITest the app can start with windows the automation harness
    /// restored rather than the launcher, which made these tests fail on the
    /// state left by a previous run instead of on anything real. File ▸ Open
    /// Project… opens it or focuses it either way, so the test starts from a
    /// known place.
    @MainActor
    private func openLauncher() {
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 45), "The app did not finish launching.")
        fileMenu.click()
        app.menuItems["Open Project…"].click()
    }

    override func tearDown() {
        app.terminate()
        app = nil
    }

    @MainActor
    func testCreatesAProjectAndRequestAndEditsIt() throws {
        // Arrange
        openLauncher()

        // Assert -- an empty folder offers a new project, not a folder picker
        let newProject = launcher.buttons["New Project"]
        XCTAssertTrue(newProject.waitForExistence(timeout: 30), "The launcher did not open.")
        XCTAssertTrue(launcher.staticTexts["No projects yet."].exists)

        // Act -- a new project opens in its own window, named for the project
        newProject.click()
        let window = projectWindow("Untitled Project")
        XCTAssertTrue(
            window.waitForExistence(timeout: 15),
            "A new project did not open its own window, titled with its name."
        )
        // The launcher closes itself once it has opened something. Waiting for
        // that is not politeness: until it goes it can sit over the project
        // window's bottom-left corner, where the new-request button lives, and
        // an obscured element is not hittable.
        XCTAssertTrue(
            launcher.waitForNonExistence(timeout: 10),
            "The launcher stayed open after opening a project."
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

        // Assert -- the sidebar's bottom bar is inside its window. If the window
        // is too narrow for all three columns the split view overflows and the
        // sidebar lands outside it, which is the regression worth catching.
        //
        // Containment, not hittability: the bar sits in the window's bottom-left
        // corner, and on a small screen the Dock covers that corner -- CI runs
        // at 1024x768, where the button is on screen and enabled but has the
        // Dock on top of it. Whether the desktop happens to cover a corner is
        // not this app's layout.
        let requestButton = window.buttons["Request"]
        XCTAssertTrue(requestButton.exists, "The sidebar has no new-request button.")
        XCTAssertTrue(
            window.frame.contains(requestButton.frame),
            "The sidebar's bottom bar is outside the window. "
                + "window=\(window.frame) button=\(requestButton.frame)"
        )

        // Act -- create a request from the project row's menu rather than that
        // button, so the test does not depend on the corner being clickable.
        let projectRow = window.outlines.cells.staticTexts["Untitled Project"]
        XCTAssertTrue(projectRow.waitForExistence(timeout: 5), "The project row is missing.")
        projectRow.rightClick()
        app.menuItems["New Request"].click()
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
        openLauncher()
        let newProject = launcher.buttons["New Project"]
        XCTAssertTrue(newProject.waitForExistence(timeout: 30), "The launcher did not open.")
        newProject.click()

        let window = projectWindow("Untitled Project")
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        XCTAssertTrue(launcher.waitForNonExistence(timeout: 10))
        let windowCount = app.windows.count

        // Arrange -- give it a request. A new project is held in memory until
        // something about it changes, so an untouched one is deliberately not
        // written and would not be listed to reopen.
        let projectRow = window.outlines.cells.staticTexts["Untitled Project"]
        XCTAssertTrue(projectRow.waitForExistence(timeout: 5), "The project row is missing.")
        projectRow.rightClick()
        app.menuItems["New Request"].click()
        XCTAssertTrue(
            window.textFields["https://example.com/path?query=value"]
                .waitForExistence(timeout: 8),
            "The request was not created."
        )

        // Act -- back to the launcher and open the same project again
        openLauncher()
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
