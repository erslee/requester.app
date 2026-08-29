import Foundation
import Testing
@testable import requester

/// A new project is held in memory until something about it changes, so that
/// opening one and closing it again leaves no empty project behind. What
/// matters is which actions count as a change -- and that reading never does.
@MainActor
struct ProjectPersistenceTests {
    private func makeModel(
        _ storage: any StorageBackend, project: Project
    ) -> AppModel {
        AppModel(
            storage: storage,
            projectID: project.id,
            unsavedProject: project,
            interfaceState: InterfaceStateStore(
                projectID: project.id,
                defaults: UserDefaults(suiteName: "requester-tests-\(UUID().uuidString)")!
            )
        )
    }

    private func newProject() -> Project {
        Project(id: ProjectRepository.newIdentifier(), name: "Untitled Project")
    }

    private func isOnDisk(_ project: Project, in storage: any StorageBackend) async -> Bool {
        await storage.exists(at: "projects/\(project.id)/project.json")
    }

    /// The whole point: a window opened and closed without a single edit must
    /// leave the data folder exactly as it found it.
    @Test func openingAndReadingWritesNothing() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let project = newProject()
        let model = makeModel(storage, project: project)

        // Act -- everything a window does just by being open
        await model.load()
        await model.reloadProjects()
        await model.reloadRequests(projectID: project.id)
        await model.reloadVariables(projectID: project.id)

        // Assert -- nothing on disk, but the window still shows the project
        #expect(await isOnDisk(project, in: storage) == false)
        #expect(model.isProjectUnsaved)
        #expect(model.project?.name == "Untitled Project")
        #expect(try await ProjectRepository(storage: storage).listAll().isEmpty)
    }

    @Test func renamingWritesItOnce() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let project = newProject()
        let model = makeModel(storage, project: project)
        await model.load()

        // Act
        await model.renameProject(project.id, to: "Petstore")

        // Assert -- written, with the new name, and no longer pending
        #expect(await isOnDisk(project, in: storage))
        #expect(model.isProjectUnsaved == false)
        #expect(try await ProjectRepository(storage: storage).get(project.id)?.name == "Petstore")
    }

    /// A request cannot live in a project the launcher cannot see, so adding
    /// one has to bring the project with it.
    @Test func addingARequestWritesTheProjectFirst() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let project = newProject()
        let model = makeModel(storage, project: project)
        await model.load()

        // Act
        await model.createRequest(projectID: project.id)

        // Assert
        #expect(await isOnDisk(project, in: storage))
        #expect(try await ProjectRepository(storage: storage).listAll().map(\.id) == [project.id])
        #expect(model.visibleRequests(in: project.id).count == 1)
    }

    @Test func addingAVariableWritesTheProject() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let project = newProject()
        let model = makeModel(storage, project: project)
        await model.load()

        // Act
        await model.setVariable(projectID: project.id, key: "host", value: "example.com")

        // Assert
        #expect(await isOnDisk(project, in: storage))
        #expect(model.variables(forProject: project.id).map(\.key) == ["host"])
    }

    @Test func settingAGlobalHeaderWritesTheProject() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let project = newProject()
        let model = makeModel(storage, project: project)
        await model.load()

        // Act
        await model.setProjectHeaders(
            [KeyValueItem(key: "Accept", value: "application/json")], for: project.id
        )

        // Assert
        #expect(await isOnDisk(project, in: storage))
        #expect(model.project?.globalHeaders?.map(\.key) == ["Accept"])
    }

    @Test func makingAFolderWritesTheProject() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let project = newProject()
        let model = makeModel(storage, project: project)
        await model.load()

        // Act
        await model.createFolder()

        // Assert
        #expect(await isOnDisk(project, in: storage))
        #expect(model.project?.folders == [["New Folder"]])
    }

    /// The name typed before the first save has to be the one that lands, not
    /// the placeholder the project was made with.
    @Test func materializingKeepsWhateverTheProjectHeldInMemory() async throws {
        // Arrange -- a project renamed while still unsaved
        let storage = InMemoryStorage()
        var project = newProject()
        project.name = "Renamed Before Saving"
        let model = makeModel(storage, project: project)
        await model.load()

        // Act -- a change that is not the name
        await model.createRequest(projectID: project.id)

        // Assert
        #expect(
            try await ProjectRepository(storage: storage).get(project.id)?.name
                == "Renamed Before Saving"
        )
    }

    /// Deleting one that was never written must not write it on the way out.
    @Test func deletingAnUnsavedProjectWritesNothing() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let project = newProject()
        let model = makeModel(storage, project: project)
        await model.load()

        // Act
        await model.deleteProject(project.id)

        // Assert
        #expect(await isOnDisk(project, in: storage) == false)
        #expect(model.wasDeleted)
        #expect(model.errorMessage == nil)
    }
}
