import Foundation
import Testing
@testable import requester

/// The spec link is stored inside files that already exist in every user's data
/// folder, so most of what matters here is what happens to a file written
/// before the feature existed.
struct SpecModelTests {
    // MARK: - Backwards compatibility

    /// Swift's synthesized `Decodable` ignores property defaults and throws on a
    /// missing key, so this is the test that catches `specSource` being made
    /// non-optional: every project on disk would stop loading.
    @Test func projectWithoutASpecSourceStillDecodes() throws {
        // Arrange -- exactly what ProjectRepository wrote before this feature
        let json = """
            {
              "createdAt" : "2026-07-18T13:22:39.000Z",
              "description" : "",
              "id" : "6a1f2c9e4b7d40a8b5c3e1f09d2a7b64",
              "name" : "Space API",
              "updatedAt" : "2026-07-18T13:22:39.000Z"
            }
            """

        // Act
        let project = try JSONCoding.decoder.decode(Project.self, from: Data(json.utf8))

        // Assert
        #expect(project.name == "Space API")
        #expect(project.specSource == nil)
    }

    @Test func requestWithoutASpecLinkStillDecodes() throws {
        // Arrange
        let json = """
            {
              "auth" : {
                "apiKeyIn" : "header",
                "apiKeyName" : "",
                "apiKeyValue" : "",
                "basicPassword" : "",
                "basicUsername" : "",
                "bearerToken" : "",
                "type" : "none"
              },
              "bodyMode" : "none",
              "createdAt" : "2026-07-18T13:22:39.000Z",
              "formFields" : [],
              "headers" : [],
              "id" : "b2d4f6a8c0e2f4a6b8d0c2e4f6a8b0d2",
              "method" : "GET",
              "name" : "Planets",
              "order" : 0,
              "params" : [],
              "postResponseScript" : "",
              "projectID" : "6a1f2c9e4b7d40a8b5c3e1f09d2a7b64",
              "rawBody" : "",
              "rawBodyType" : "json",
              "scriptTimeoutSeconds" : 5,
              "updatedAt" : "2026-07-18T13:22:39.000Z",
              "url" : "https://swapi.info/api/planets"
            }
            """

        // Act
        let request = try JSONCoding.decoder.decode(APIRequest.self, from: Data(json.utf8))

        // Assert
        #expect(request.name == "Planets")
        #expect(request.spec == nil, "A hand-made request must stay unlinked, so no sync touches it.")
    }

    // MARK: - Round trips

    @Test func specSourceSurvivesARoundTrip() throws {
        // Arrange
        var source = SpecSource(kind: .url)
        source.url = "{{host}}/openapi.json"
        source.headers = [KeyValueItem(key: "Authorization", value: "Bearer {{token}}")]
        source.lastSyncedAt = Date(timeIntervalSince1970: 1_800_000_000)

        // Act
        let data = try JSONCoding.prettyEncoder.encode(source)
        let decoded = try JSONCoding.decoder.decode(SpecSource.self, from: data)

        // Assert -- compared field by field rather than whole-struct: a
        // KeyValueItem's `id` is a UI identity that is deliberately not
        // persisted, so a decoded header always carries a fresh UUID and
        // `decoded == source` could never hold.
        #expect(decoded.kind == .url)
        #expect(decoded.url == source.url)
        #expect(decoded.lastSyncedAt == source.lastSyncedAt)
        #expect(decoded.headers.map(\.key) == ["Authorization"])
        #expect(decoded.headers.map(\.value) == ["Bearer {{token}}"])
    }

    @Test func specLinkSurvivesARoundTripOnARequest() throws {
        // Arrange
        var request = APIRequest(id: "r1", projectID: "p1")
        request.spec = SpecLink(
            key: "GET /users/{id}",
            removedAt: Date(timeIntervalSince1970: 1_800_000_000),
            generatedBody: #"{"name":"string"}"#
        )

        // Act
        let data = try JSONCoding.prettyEncoder.encode(request)
        let decoded = try JSONCoding.decoder.decode(APIRequest.self, from: data)

        // Assert
        #expect(decoded.spec == request.spec)
        #expect(decoded.spec?.isRemoved == true)
    }

    @Test func aLinkWithNoRemovalDateIsNotRemoved() {
        #expect(SpecLink(key: "GET /users").isRemoved == false)
    }

    // MARK: - Dirty comparison

    /// A sync marking an operation removed must not make an untouched request
    /// look edited in the sidebar, so the link is excluded from the comparison
    /// `EditorModel.isDirty` runs.
    @Test func theSpecLinkIsNotPartOfTheDirtyComparison() {
        // Arrange
        var saved = APIRequest(id: "r1", projectID: "p1")
        saved.url = "https://api.acme.dev/users"
        saved.spec = SpecLink(key: "GET /users")

        var synced = saved
        synced.spec?.removedAt = Date()

        // Act / Assert
        #expect(synced.editableContent == saved.editableContent)
    }

    /// The guard on the guard: a real edit must still register as one.
    @Test func anActualEditStillCountsAsDirty() {
        // Arrange
        var saved = APIRequest(id: "r1", projectID: "p1")
        saved.spec = SpecLink(key: "GET /users")
        var edited = saved
        edited.url = "https://api.acme.dev/users?page=2"

        // Act / Assert
        #expect(edited.editableContent != saved.editableContent)
    }

    // MARK: - Display

    @Test func aSourceNamesItselfBeforeItHasEverSynced() {
        #expect(SpecSource(kind: .url).displayName == "Untitled link")
        #expect(SpecSource(kind: .file).displayName == "Uploaded file")
    }
}

/// `setSpecSource` is the only way anything above the repository layer attaches
/// or detaches a spec, so it owns the path and the `updatedAt` bump.
struct ProjectSpecSourceTests {
    @Test func attachesUpdatesAndDetachesASpecSource() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let projects = ProjectRepository(storage: storage)
        let project = try await projects.create(name: "Acme")

        var source = SpecSource(kind: .url)
        source.url = "https://api.acme.dev/openapi.json"

        // Act -- attach
        let attached = try await projects.setSpecSource(source, for: project.id)

        // Assert -- and that it survives a read back off storage
        #expect(attached.specSource?.url == "https://api.acme.dev/openapi.json")
        #expect(try await projects.get(project.id)?.specSource?.kind == .url)

        // Act -- detach
        let detached = try await projects.setSpecSource(nil, for: project.id)

        // Assert
        #expect(detached.specSource == nil)
        #expect(try await projects.get(project.id)?.specSource == nil)
    }

    @Test func settingASourceOnAMissingProjectReports() async throws {
        // Arrange
        let projects = ProjectRepository(storage: InMemoryStorage())

        // Act / Assert
        await #expect(throws: StorageError.self) {
            _ = try await projects.setSpecSource(SpecSource(), for: "nope")
        }
    }
}
