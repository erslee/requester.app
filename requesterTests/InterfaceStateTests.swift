import Foundation
import Testing
@testable import requester

/// The sidebar's shape and selection are restored on launch, so both the saving
/// and the guards against restoring something that no longer exists matter.
@MainActor
struct InterfaceStateTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "requester-tests-\(UUID().uuidString)")!
    }

    // MARK: - The store

    @Test func remembersCollapsedProjects() {
        // Arrange
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let store = InterfaceStateStore(defaults: defaults)

        // Act / Assert -- nothing saved yet
        #expect(store.collapsedProjectIDs.isEmpty)

        // Act
        store.collapsedProjectIDs = ["a", "b"]

        // Assert -- a fresh store over the same defaults sees it
        #expect(InterfaceStateStore(defaults: defaults).collapsedProjectIDs == ["a", "b"])

        // Act -- expanding everything clears the key rather than storing []
        store.collapsedProjectIDs = []
        #expect(InterfaceStateStore(defaults: defaults).collapsedProjectIDs.isEmpty)
    }

    @Test func remembersEitherKindOfSelection() {
        // Arrange
        let defaults = makeDefaults()
        let store = InterfaceStateStore(defaults: defaults)

        // Act / Assert -- a project
        store.selection = .project("p1")
        #expect(InterfaceStateStore(defaults: defaults).selection == .project("p1"))

        // Act / Assert -- a request, with both ids intact
        store.selection = .request(projectID: "p1", requestID: "r1")
        #expect(
            InterfaceStateStore(defaults: defaults).selection
                == .request(projectID: "p1", requestID: "r1")
        )

        // Act / Assert -- cleared
        store.selection = nil
        #expect(InterfaceStateStore(defaults: defaults).selection == nil)
    }

    // MARK: - Restoring

    private func makeModel(_ defaults: UserDefaults, storage: any StorageBackend) -> AppModel {
        AppModel(storage: storage, interfaceState: InterfaceStateStore(defaults: defaults))
    }

    @Test func restoresTheCollapsedProjectAndTheSelectedRequest() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let projects = ProjectRepository(storage: storage)
        let open = try await projects.create(name: "Open")
        let folded = try await projects.create(name: "Folded")
        let request = try await RequestRepository(storage: storage)
            .create(projectID: open.id, name: "Planets")

        let defaults = makeDefaults()
        let saved = InterfaceStateStore(defaults: defaults)
        saved.collapsedProjectIDs = [folded.id]
        saved.selection = .request(projectID: open.id, requestID: request.id)

        // Act
        let model = makeModel(defaults, storage: storage)
        await model.load()

        // Assert
        #expect(model.isExpanded(open.id))
        #expect(model.isExpanded(folded.id) == false)
        #expect(model.selection == .request(projectID: open.id, requestID: request.id))
    }

    /// A different data folder, or a project deleted elsewhere, would otherwise
    /// leave the app selecting something that is not there.
    @Test func dropsASelectionWhoseProjectIsGone() async throws {
        // Arrange
        let storage = InMemoryStorage()
        _ = try await ProjectRepository(storage: storage).create(name: "Only")

        let defaults = makeDefaults()
        let saved = InterfaceStateStore(defaults: defaults)
        saved.collapsedProjectIDs = ["vanished"]
        saved.selection = .project("vanished")

        // Act
        let model = makeModel(defaults, storage: storage)
        await model.load()

        // Assert -- nothing selected, and the stale id is pruned from storage
        #expect(model.selection == nil)
        #expect(InterfaceStateStore(defaults: defaults).selection == nil)
        #expect(InterfaceStateStore(defaults: defaults).collapsedProjectIDs.isEmpty)
    }

    /// The project survives but the request does not: landing on the project is
    /// closer to where the user was than landing nowhere.
    @Test func fallsBackToTheProjectWhenTheRequestIsGone() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let project = try await ProjectRepository(storage: storage).create(name: "Kept")

        let defaults = makeDefaults()
        InterfaceStateStore(defaults: defaults).selection =
            .request(projectID: project.id, requestID: "deleted")

        // Act
        let model = makeModel(defaults, storage: storage)
        await model.load()

        // Assert
        #expect(model.selection == .project(project.id))
    }

    @Test func savesTheSelectionAsItChanges() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let project = try await ProjectRepository(storage: storage).create(name: "P")
        let defaults = makeDefaults()
        let model = makeModel(defaults, storage: storage)
        await model.load()

        // Act
        model.selection = .project(project.id)

        // Assert -- written straight away, not only on quit
        #expect(InterfaceStateStore(defaults: defaults).selection == .project(project.id))
    }

    @Test func savesCollapsingAndExpanding() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let project = try await ProjectRepository(storage: storage).create(name: "P")
        let defaults = makeDefaults()
        let model = makeModel(defaults, storage: storage)
        await model.load()

        // Act -- collapse
        model.toggleExpansion(project.id)

        // Assert
        #expect(model.isExpanded(project.id) == false)
        #expect(InterfaceStateStore(defaults: defaults).collapsedProjectIDs == [project.id])

        // Act -- expand again
        model.toggleExpansion(project.id)

        // Assert
        #expect(model.isExpanded(project.id))
        #expect(InterfaceStateStore(defaults: defaults).collapsedProjectIDs.isEmpty)
    }
}

/// Which rows the sidebar draws for a project, and the guard that keeps the
/// selected one from vanishing out from under the user.
@MainActor
struct RemovedEndpointVisibilityTests {
    private func makeModel() -> AppModel {
        AppModel(
            storage: InMemoryStorage(),
            interfaceState: InterfaceStateStore(
                defaults: UserDefaults(suiteName: "requester-tests-\(UUID().uuidString)")!
            )
        )
    }

    private func request(_ id: String, removed: Bool) -> APIRequest {
        var request = APIRequest(id: id, projectID: "p1")
        request.spec = SpecLink(key: "operationId:\(id)")
        if removed { request.spec?.removedAt = Date() }
        return request
    }

    @Test func removedEndpointsAreHiddenUntilAskedFor() {
        // Arrange
        let model = makeModel()
        model.requestsByProject["p1"] = [
            request("live", removed: false),
            request("gone", removed: true),
        ]

        // Assert -- hidden by default, and counted so the toggle can say so
        #expect(model.visibleRequests(in: "p1").map(\.id) == ["live"])
        #expect(model.removedRequestCount(in: "p1") == 1)

        // Act
        model.showsRemovedEndpoints = true

        // Assert
        #expect(model.visibleRequests(in: "p1").map(\.id) == ["live", "gone"])
    }

    /// Selecting a removed endpoint and then hiding removed endpoints would
    /// otherwise leave the detail pane showing a request with no row anywhere.
    @Test func theSelectedRemovedEndpointStaysVisible() {
        // Arrange
        let model = makeModel()
        model.requestsByProject["p1"] = [
            request("live", removed: false),
            request("gone", removed: true),
        ]
        model.showsRemovedEndpoints = false

        // Act
        model.selection = .request(projectID: "p1", requestID: "gone")

        // Assert
        #expect(model.showsRemovedEndpoints)
        #expect(model.visibleRequests(in: "p1").map(\.id) == ["live", "gone"])
    }

    @Test func aHandMadeRequestIsNeverHidden() {
        // Arrange
        let model = makeModel()
        model.requestsByProject["p1"] = [APIRequest(id: "mine", projectID: "p1")]

        // Act / Assert
        #expect(model.visibleRequests(in: "p1").map(\.id) == ["mine"])
        #expect(model.removedRequestCount(in: "p1") == 0)
    }
}

