import Foundation
import Testing
@testable import requester

/// Where a new request lands is read off the selection, so the three cases the
/// sidebar can be in are what matter -- plus the reveal that has to happen for
/// the new row to be selectable at all.
@MainActor
struct SidebarTargetingTests {
    private func makeModel(storage: any StorageBackend, projectID: String) -> AppModel {
        AppModel(
            storage: storage,
            projectID: projectID,
            interfaceState: InterfaceStateStore(
                projectID: projectID,
                defaults: UserDefaults(suiteName: "requester-tests-\(UUID().uuidString)")!
            )
        )
    }

    /// A project with one request filed under `Users ▸ Admin`.
    private func loadedModel() async throws -> (AppModel, APIRequest) {
        let storage = InMemoryStorage()
        let project = try await ProjectRepository(storage: storage).create(name: "Petstore")
        let filed = try await RequestRepository(storage: storage)
            .create(projectID: project.id, name: "promote", folder: ["Users", "Admin"])

        let model = makeModel(storage: storage, projectID: project.id)
        await model.load()
        return (model, filed)
    }

    @Test func aSelectedFolderIsWhereANewRequestGoes() async throws {
        // Arrange
        let (model, _) = try await loadedModel()

        // Act
        model.selection = .folder(projectID: model.projectID, path: ["Users"])

        // Assert
        #expect(model.targetFolderForNewRequest == ["Users"])
    }

    /// Adding next to the request you are looking at is what "here" means when
    /// a request rather than a folder is selected.
    @Test func aSelectedRequestPutsTheNewOneBesideIt() async throws {
        // Arrange
        let (model, filed) = try await loadedModel()

        // Act
        model.selection = .request(projectID: model.projectID, requestID: filed.id)

        // Assert
        #expect(model.targetFolderForNewRequest == ["Users", "Admin"])
    }

    @Test func theProjectRowMeansTheTopLevel() async throws {
        // Arrange
        let (model, _) = try await loadedModel()

        // Act
        model.selection = .project(model.projectID)

        // Assert
        #expect(model.targetFolderForNewRequest == [])
    }

    /// A row inside a collapsed folder cannot be selected, so creating one has
    /// to open the way to it first -- every level of it.
    @Test func creatingARequestRevealsSelectsAndScrollsToIt() async throws {
        // Arrange -- both folders shut
        let (model, _) = try await loadedModel()
        model.toggleExpansion(folder: ["Users"])
        model.toggleExpansion(folder: ["Users", "Admin"])
        #expect(!model.isExpanded(folder: ["Users"]))

        // Act
        await model.createRequest(projectID: model.projectID, folder: ["Users", "Admin"])

        // Assert -- the whole path is open again
        #expect(model.isExpanded(folder: ["Users"]))
        #expect(model.isExpanded(folder: ["Users", "Admin"]))

        // Assert -- the new request is selected, and the sidebar told to reveal it
        let created = try #require(
            model.visibleRequests(in: model.projectID).first { $0.name.isEmpty }
        )
        #expect(model.selection == .request(projectID: model.projectID, requestID: created.id))
        #expect(model.pendingScrollTarget == model.selection)
        #expect(created.folder == ["Users", "Admin"])
    }

    /// Opening a past send moves the editor to that request, so the sidebar has
    /// to move with it -- otherwise the editor shows a request the tree is not
    /// pointing at, somewhere off screen or inside a shut folder.
    @Test func openingAHistoryEntryRevealsAndScrollsToItsRequest() async throws {
        // Arrange -- the request is filed two folders deep, both shut
        let (model, filed) = try await loadedModel()
        model.toggleExpansion(folder: ["Users"])
        model.toggleExpansion(folder: ["Users", "Admin"])
        #expect(!model.isExpanded(folder: ["Users", "Admin"]))

        let entry = HistoryEntry(
            id: "h1",
            projectID: model.projectID,
            requestID: filed.id,
            requestSnapshot: filed,
            resolvedURL: "https://example.com/users/1/promote",
            sentAt: Date()
        )

        // Act
        model.open(historyEntry: entry)

        // Assert -- the way to the row is open, and the sidebar was told to
        // bring it into view
        let target = SidebarSelection.request(projectID: model.projectID, requestID: filed.id)
        #expect(model.isExpanded(folder: ["Users"]))
        #expect(model.isExpanded(folder: ["Users", "Admin"]))
        #expect(model.pendingScrollTarget == target)
    }
}
