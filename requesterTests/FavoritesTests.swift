import Foundation
import Testing
@testable import requester

/// Starring a request is a write to the request's own file, so what matters is
/// that it survives a round trip, that a file written before the flag existed
/// still decodes, and that it never makes an open draft look unsaved.
struct FavoriteRequestTests {
    // MARK: - The flag on the model

    @Test func aRequestIsNotFavoriteUntilItIsStarred() {
        // Arrange
        var request = APIRequest(id: "r1", projectID: "p1", name: "List users")

        // Act / Assert
        #expect(request.isFavorite == false)

        // Act
        request.isFavorite = true

        // Assert
        #expect(request.isFavorite)
        #expect(request.favorite == true)
    }

    /// Unstarring clears the key rather than writing `false`, so a request that
    /// was never starred and one that has been unstarred are the same file.
    @Test func unstarringClearsTheStoredFlag() {
        // Arrange
        var request = APIRequest(id: "r1", projectID: "p1")
        request.isFavorite = true

        // Act
        request.isFavorite = false

        // Assert
        #expect(request.favorite == nil)
        #expect(request.isFavorite == false)
    }

    /// Every request file written before this feature existed lacks the key,
    /// and must still load.
    @Test func decodesARequestWrittenBeforeTheFlagExisted() throws {
        // Arrange
        let json = """
        {
          "id": "r1", "projectID": "p1", "name": "List users",
          "method": "GET", "url": "https://example.com/users",
          "params": [], "headers": [], "bodyMode": "none",
          "rawBody": "", "rawBodyType": "json", "formFields": [],
          "auth": { "type": "none", "basicUsername": "", "basicPassword": "",
                    "bearerToken": "", "apiKeyName": "", "apiKeyValue": "",
                    "apiKeyIn": "header" },
          "postResponseScript": "", "scriptTimeoutSeconds": 5,
          "order": 0,
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z"
        }
        """

        // Act
        let request = try JSONCoding.decoder.decode(
            APIRequest.self, from: Data(json.utf8)
        )

        // Assert
        #expect(request.isFavorite == false)
    }

    /// Starring is bookkeeping, like the spec link: it is written straight to
    /// disk from the sidebar, so it must not light the unsaved-changes dot on a
    /// draft the user has not touched.
    @Test func starringIsNotAnUnsavedChange() {
        // Arrange
        let draft = APIRequest(id: "r1", projectID: "p1", name: "List users")
        var starred = draft
        starred.isFavorite = true

        // Assert
        #expect(draft.editableContent == starred.editableContent)
    }

    // MARK: - The repository write

    @Test func starringPersistsAndIsIdempotent() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let repository = RequestRepository(storage: storage)
        let project = try await ProjectRepository(storage: storage).create(name: "Petstore")
        let request = try await repository.create(projectID: project.id, name: "List users")

        // Act
        let starred = try await repository.setFavorite(
            projectID: project.id, requestID: request.id, true
        )

        // Assert -- written, and readable back off storage
        #expect(starred?.isFavorite == true)
        let reread = try await repository.get(projectID: project.id, requestID: request.id)
        #expect(reread?.isFavorite == true)

        // Act -- starring an already starred request changes nothing
        let again = try await repository.setFavorite(
            projectID: project.id, requestID: request.id, true
        )

        // Assert
        #expect(again == nil)

        // Act
        let unstarred = try await repository.setFavorite(
            projectID: project.id, requestID: request.id, false
        )

        // Assert
        #expect(unstarred?.isFavorite == false)
        #expect(
            try await repository.get(projectID: project.id, requestID: request.id)?.favorite == nil
        )
    }
}

/// What the sidebar's Favorites tab is built on: the starred requests of the
/// window's project, narrowed by the same filter the tree uses.
@MainActor
struct FavoritesTabTests {
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

    /// A project with two requests, neither starred yet.
    private func loadedModel() async throws -> (AppModel, APIRequest, APIRequest) {
        let storage = InMemoryStorage()
        let project = try await ProjectRepository(storage: storage).create(name: "Petstore")
        let requests = RequestRepository(storage: storage)
        var users = try await requests.create(projectID: project.id, name: "List users")
        users.url = "https://example.com/users"
        users = try await requests.save(users)
        let login = try await requests.create(
            projectID: project.id, name: "Login", folder: ["Auth"]
        )

        let model = makeModel(storage: storage, projectID: project.id)
        await model.load()
        return (model, users, login)
    }

    @Test func starringPutsARequestOnTheFavoritesTab() async throws {
        // Arrange
        let (model, users, _) = try await loadedModel()

        // Assert -- nothing is starred to begin with
        #expect(model.favoriteRequests.isEmpty)
        #expect(model.hasFavorites == false)

        // Act
        await model.toggleFavorite(projectID: model.projectID, requestID: users.id)

        // Assert
        #expect(model.favoriteRequests.map(\.id) == [users.id])
        #expect(model.hasFavorites)
        #expect(model.isFavorite(requestID: users.id))

        // Act -- the same command takes it off again
        await model.toggleFavorite(projectID: model.projectID, requestID: users.id)

        // Assert
        #expect(model.favoriteRequests.isEmpty)
        #expect(model.isFavorite(requestID: users.id) == false)
    }

    /// The filter field sits under both tabs, so it has to narrow both.
    @Test func theFilterNarrowsTheFavoritesTab() async throws {
        // Arrange
        let (model, users, login) = try await loadedModel()
        await model.toggleFavorite(projectID: model.projectID, requestID: users.id)
        await model.toggleFavorite(projectID: model.projectID, requestID: login.id)

        // Act
        model.filterQuery = "login"

        // Assert -- only the matching favorite is left
        #expect(model.favoriteRequests.map(\.id) == [login.id])
        // Assert -- and the tab still knows it has favorites the filter is hiding
        #expect(model.hasFavorites)
    }

    /// `EditorModel.save` writes the whole draft, so a draft left carrying the
    /// old flag would quietly unstar the request on the next autosave.
    @Test func starringTheOpenRequestUpdatesItsDraft() async throws {
        // Arrange
        let (model, users, _) = try await loadedModel()
        model.selection = .request(projectID: model.projectID, requestID: users.id)
        // The selection loads the request in a detached task.
        while model.editor.draft?.id != users.id { await Task.yield() }

        // Act
        await model.toggleFavorite(projectID: model.projectID, requestID: users.id)

        // Assert
        #expect(model.editor.draft?.isFavorite == true)
        // Assert -- and starring is not an edit, so nothing looks unsaved
        #expect(model.editor.isDirty == false)
    }
}
