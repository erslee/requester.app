import XCTest

/// Confirms the app comes up ready to use: no first-run prompt, the launcher
/// ready to open or make a project, and the data-folder commands available for
/// anyone who wants to move it.
final class RequesterUITests: XCTestCase {
    private var app: XCUIApplication!

    private var launcher: XCUIElement { app.windows["Requester"] }

    /// The window's own floor: `ContentView`'s sidebar, detail, and inspector
    /// minimums (190 + 460 + 250), below which the three columns cannot fit.
    /// Not the 1320 preferred default -- AppKit clamps a new window to the
    /// display, and CI runs on a 1024x768 screen, so the default never applies
    /// there. Duplicated rather than imported: a UI test drives the app from
    /// another process and does not link it.
    private static let minimumWindowWidth: CGFloat = 900

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
    func testOpensOnTheLauncherWithoutAskingForAFolder() throws {
        // Arrange
        openLauncher()

        // Assert -- the launcher, not a folder picker
        XCTAssertTrue(
            launcher.buttons["New Project"].waitForExistence(timeout: 30),
            "The launcher did not open."
        )
        XCTAssertFalse(
            app.staticTexts["Choose a Folder for Your Data"].exists,
            "The app should not ask for a folder on launch."
        )
        XCTAssertFalse(
            app.staticTexts["Could Not Open Your Data"].exists,
            "The app failed to open its data folder."
        )
        XCTAssertTrue(
            launcher.buttons["New Project"].isHittable,
            "The launcher's actions are outside the window."
        )

        let attachment = XCTAttachment(screenshot: launcher.screenshot())
        attachment.name = "Launcher"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The project window carries the three-column layout, so its floor is the
    /// one worth asserting -- the launcher is a small window by design.
    @MainActor
    func testAProjectWindowIsWideEnoughForItsThreeColumns() throws {
        // Act
        openLauncher()
        let newProject = launcher.buttons["New Project"]
        XCTAssertTrue(newProject.waitForExistence(timeout: 30), "The launcher did not open.")
        newProject.click()

        // Assert
        let window = app.windows["Untitled Project"]
        XCTAssertTrue(window.waitForExistence(timeout: 15), "The project window did not open.")
        XCTAssertGreaterThanOrEqual(
            window.frame.width,
            Self.minimumWindowWidth,
            "The window is narrower than its three columns need."
        )
        // Containment rather than hittability, for the same reason as in
        // MainWindowUITests: the button is in the window's bottom-left corner,
        // which the Dock covers on a small screen. What matters here is that
        // the sidebar is inside its window, not what the desktop is doing.
        let requestButton = window.buttons["Request"]
        XCTAssertTrue(requestButton.exists, "The sidebar has no new-request button.")
        XCTAssertTrue(
            window.frame.contains(requestButton.frame),
            "The sidebar is outside the window. "
                + "window=\(window.frame) button=\(requestButton.frame)"
        )

        // Assert -- the history inspector is showing, as it is by default
        XCTAssertTrue(
            window.staticTexts["History for every request in this project"].exists
                || window.staticTexts["No History"].exists,
            "The history inspector is not visible."
        )
    }

    @MainActor
    func testFileMenuOffersTheDataFolderCommand() throws {
        // Act
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 20))
        fileMenu.click()

        // Assert -- the folder is fixed, so revealing it is the only command
        XCTAssertTrue(
            app.menuItems["Reveal Data Folder in Finder"].waitForExistence(timeout: 5),
            "Reveal Data Folder is missing."
        )
        XCTAssertFalse(app.menuItems["Change Data Folder…"].exists)
    }
}
