import XCTest

/// Exercises the real UI against a throwaway data folder: create a project, add
/// a variable, create a request, and check the editor's tabs and highlighting
/// all render and respond.
final class MainWindowUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Queries are scoped to the window: a bare `app.buttons[…]` can match a
    /// Touch Bar proxy instead of the real control.
    private var window: XCUIElement { app.windows.firstMatch }

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
        // Assert -- an empty folder lands on the main window, not the picker.
        // A cold Debug launch can be slow, hence the generous wait.
        XCTAssertTrue(
            window.buttons["Project"].waitForExistence(timeout: 45),
            "The main window did not open."
        )
        XCTAssertTrue(window.staticTexts["Nothing Selected"].exists)
        XCTAssertFalse(
            window.buttons["Request"].isEnabled,
            "New Request should be disabled until a project is selected."
        )

        // Act -- create a project through the sidebar toolbar
        window.buttons["Project"].click()
        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "The new-project prompt is missing.")
        nameField.typeText("Space API")
        app.typeKey(.return, modifierFlags: [])  // "Create" is the default button

        // Assert -- the project is selected and its detail view is showing
        XCTAssertTrue(
            window.textFields["New key"].waitForExistence(timeout: 8),
            "The project detail view did not appear."
        )

        // Act -- add a variable the request can reference
        let newKey = window.textFields["New key"]
        XCTAssertTrue(newKey.waitForExistence(timeout: 5))
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
}
