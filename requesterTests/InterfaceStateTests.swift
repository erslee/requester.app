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

    @Test func remembersWhetherTheProjectIsCollapsed() {
        // Arrange
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let store = InterfaceStateStore(projectID: "p1", defaults: defaults)

        // Act / Assert -- expanded is the default, so nothing is stored yet
        #expect(store.isProjectCollapsed == false)

        // Act
        store.isProjectCollapsed = true

        // Assert -- a fresh store over the same defaults sees it
        #expect(InterfaceStateStore(projectID: "p1", defaults: defaults).isProjectCollapsed)

        // Act -- expanding again clears the key rather than storing false
        store.isProjectCollapsed = false

        // Assert
        #expect(InterfaceStateStore(projectID: "p1", defaults: defaults).isProjectCollapsed == false)
    }

    /// Two windows must not overwrite each other's state, which is the whole
    /// reason the keys carry a project id.
    @Test func keepsEachProjectsStateApart() {
        // Arrange
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let first = InterfaceStateStore(projectID: "p1", defaults: defaults)
        let second = InterfaceStateStore(projectID: "p2", defaults: defaults)

        // Act
        first.selection = .request(projectID: "p1", requestID: "r1")
        first.isProjectCollapsed = true
        second.selection = .project("p2")

        // Assert -- neither disturbed the other
        #expect(first.selection == .request(projectID: "p1", requestID: "r1"))
        #expect(second.selection == .project("p2"))
        #expect(second.isProjectCollapsed == false)

        // Act -- deleting one project forgets only its own keys
        first.forgetProject()

        // Assert
        #expect(first.selection == nil)
        #expect(second.selection == .project("p2"))
    }

    @Test func remembersTheSelection() {
        // Arrange
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let store = InterfaceStateStore(projectID: "p1", defaults: defaults)

        // Act
        store.selection = .project("p1")

        // Assert
        #expect(InterfaceStateStore(projectID: "p1", defaults: defaults).selection == .project("p1"))

        // Act
        store.selection = nil

        // Assert
        #expect(InterfaceStateStore(projectID: "p1", defaults: defaults).selection == nil)
    }

    // MARK: - Restoring

    private func makeModel(
        _ defaults: UserDefaults, storage: any StorageBackend, projectID: String
    ) -> AppModel {
        AppModel(
            storage: storage,
            projectID: projectID,
            interfaceState: InterfaceStateStore(projectID: projectID, defaults: defaults)
        )
    }

    @Test func restoresTheCollapsedRowAndTheSelectedRequest() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let project = try await ProjectRepository(storage: storage).create(name: "Open")
        let request = try await RequestRepository(storage: storage)
            .create(projectID: project.id, name: "Planets")

        let defaults = makeDefaults()
        let saved = InterfaceStateStore(projectID: project.id, defaults: defaults)
        saved.isProjectCollapsed = true
        saved.selection = .request(projectID: project.id, requestID: request.id)

        // Act
        let model = makeModel(defaults, storage: storage, projectID: project.id)
        await model.load()

        // Assert
        #expect(model.isExpanded(project.id) == false)
        #expect(model.selection == .request(projectID: project.id, requestID: request.id))
    }

    /// The project survives but the request does not: landing on the project is
    /// closer to where the user was than landing nowhere.
    @Test func fallsBackToTheProjectWhenTheRequestIsGone() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let project = try await ProjectRepository(storage: storage).create(name: "Kept")

        let defaults = makeDefaults()
        InterfaceStateStore(projectID: project.id, defaults: defaults).selection =
            .request(projectID: project.id, requestID: "deleted")

        // Act
        let model = makeModel(defaults, storage: storage, projectID: project.id)
        await model.load()

        // Assert
        #expect(model.selection == .project(project.id))
    }

    /// A selection saved against a different project must not leak into this
    /// window -- it would open a request the window is not even showing.
    @Test func ignoresASelectionBelongingToAnotherProject() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let project = try await ProjectRepository(storage: storage).create(name: "Mine")

        let defaults = makeDefaults()
        InterfaceStateStore(projectID: project.id, defaults: defaults).selection =
            .request(projectID: "somebody-else", requestID: "r1")

        // Act
        let model = makeModel(defaults, storage: storage, projectID: project.id)
        await model.load()

        // Assert -- falls back to this project's own pane
        #expect(model.selection == .project(project.id))
    }

    /// The window shows one project, whatever else is in the data folder.
    @Test func loadsOnlyItsOwnProject() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let projects = ProjectRepository(storage: storage)
        let mine = try await projects.create(name: "Mine")
        _ = try await projects.create(name: "Theirs")

        // Act
        let model = makeModel(makeDefaults(), storage: storage, projectID: mine.id)
        await model.load()

        // Assert
        #expect(model.projectList.map(\.id) == [mine.id])
        #expect(model.project?.name == "Mine")
    }
}
