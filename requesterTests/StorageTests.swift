import Foundation
import Testing
@testable import requester

/// An in-memory `StorageBackend`, so repository behaviour can be tested
/// without touching the filesystem or a real data folder.
actor InMemoryStorage: StorageBackend {
    private var files: [String: String] = [:]

    func readText(at path: String) -> String? { files[path] }

    func writeText(_ text: String, to path: String) { files[path] = text }

    func appendLine(_ line: String, to path: String) {
        files[path, default: ""] += line.trimmingCharacters(in: .newlines) + "\n"
    }

    func listDirectory(at path: String) -> [String] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return Set(
            files.keys
                .filter { $0.hasPrefix(prefix) }
                .compactMap { $0.dropFirst(prefix.count).split(separator: "/").first }
                .map(String.init)
        ).sorted()
    }

    func exists(at path: String) -> Bool { files[path] != nil }

    func delete(at path: String) { files[path] = nil }

    func deleteTree(at path: String) {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for key in files.keys where key == path || key.hasPrefix(prefix) {
            files[key] = nil
        }
    }
}

struct ProjectAndRequestRepositoryTests {
    /// Folders are paths on requests plus a list on the project, so the
    /// repository has to keep both in step.
    @Test func movesRequestsBetweenFoldersAndRenamesWholeBranches() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let projects = ProjectRepository(storage: storage)
        let requests = RequestRepository(storage: storage)
        let project = try await projects.create(name: "Petstore")

        let listUsers = try await requests.create(
            projectID: project.id, name: "listUsers", folder: ["Users"]
        )
        let promote = try await requests.create(
            projectID: project.id, name: "promote", folder: ["Users", "Admin"]
        )
        let loose = try await requests.create(projectID: project.id, name: "health")

        // Assert -- a new request lands where it was told to
        #expect(listUsers.folder == ["Users"])
        #expect(loose.folder == [])

        // Act -- move one request into a folder
        _ = try await requests.move(projectID: project.id, requestID: loose.id, to: ["Pets"])

        // Assert
        var stored = try await requests.get(projectID: project.id, requestID: loose.id)
        #expect(stored?.folder == ["Pets"])

        // Act -- rename a folder: its descendants come with it
        try await requests.moveFolder(projectID: project.id, from: ["Users"], to: ["People"])

        // Assert
        stored = try await requests.get(projectID: project.id, requestID: listUsers.id)
        #expect(stored?.folder == ["People"])
        stored = try await requests.get(projectID: project.id, requestID: promote.id)
        #expect(stored?.folder == ["People", "Admin"])
        // Untouched branches stay put
        stored = try await requests.get(projectID: project.id, requestID: loose.id)
        #expect(stored?.folder == ["Pets"])
    }

    @Test func deletingAFolderTakesItsSubtreeWithIt() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let projects = ProjectRepository(storage: storage)
        let requests = RequestRepository(storage: storage)
        let project = try await projects.create(name: "Petstore")

        _ = try await requests.create(projectID: project.id, name: "a", folder: ["Users"])
        _ = try await requests.create(
            projectID: project.id, name: "b", folder: ["Users", "Admin"]
        )
        let kept = try await requests.create(projectID: project.id, name: "c", folder: ["Pets"])

        // Act
        try await requests.deleteFolder(projectID: project.id, folder: ["Users"])

        // Assert -- the whole branch went, and nothing else did
        let remaining = try await requests.listForProject(project.id)
        #expect(remaining.map(\.id) == [kept.id])
    }

    /// An empty folder only exists because the project remembers it.
    @Test func remembersHandMadeFoldersOnTheProject() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let projects = ProjectRepository(storage: storage)
        let project = try await projects.create(name: "Petstore")

        // Act -- duplicates and empty paths are not worth storing
        let saved = try await projects.setFolders(
            [["Scratch"], ["Scratch"], [], ["Users", "Admin"]], for: project.id
        )

        // Assert
        #expect(saved.folders == [["Scratch"], ["Users", "Admin"]])
        #expect(try await projects.get(project.id)?.folders == [["Scratch"], ["Users", "Admin"]])
    }

    @Test func createsListsRenamesAndDeletesProjects() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let projects = ProjectRepository(storage: storage)

        // Act
        let zebra = try await projects.create(name: "Zebra")
        _ = try await projects.create(name: "apple")
        let renamed = try await projects.rename(zebra.id, to: "Zulu")

        // Assert -- listing is name-ordered, case-insensitively
        #expect(renamed.name == "Zulu")
        #expect(try await projects.listAll().map(\.name) == ["apple", "Zulu"])

        // Act -- deleting takes the project's own file with it
        try await projects.delete(zebra.id)
        #expect(try await projects.listAll().map(\.name) == ["apple"])
    }

    @Test func ordersRequestsByCreationAndReordersOnDemand() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let requests = RequestRepository(storage: storage)
        let first = try await requests.create(projectID: "p1", name: "first")
        let second = try await requests.create(projectID: "p1", name: "second")
        let third = try await requests.create(projectID: "p1", name: "third")

        // Act
        try await requests.reorder(
            projectID: "p1", orderedRequestIDs: [third.id, first.id, second.id]
        )

        // Assert
        let names = try await requests.listForProject("p1").map(\.name)
        #expect(names == ["third", "first", "second"])
    }

    @Test func roundTripsARequestThroughStorage() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let requests = RequestRepository(storage: storage)
        var request = try await requests.create(projectID: "p1")
        request.method = .patch
        request.url = "https://example.com/{{id}}"
        request.headers = [KeyValueItem(key: "X-Trace", value: "1", enabled: false)]
        request.bodyMode = .graphQL
        request.graphQLBody = GraphQLBody(query: "{ me }")
        request.auth.type = .bearer
        request.auth.bearerToken = "{{token}}"
        request.postResponseScript = "variables.a = 1"

        // Act
        _ = try await requests.save(request)
        let loaded = try await requests.get(projectID: "p1", requestID: request.id)

        // Assert -- every field survives the encode/decode round trip
        #expect(loaded?.method == .patch)
        #expect(loaded?.url == "https://example.com/{{id}}")
        #expect(loaded?.headers.first?.enabled == false)
        #expect(loaded?.graphQLBody?.query == "{ me }")
        #expect(loaded?.auth.bearerToken == "{{token}}")
        #expect(loaded?.postResponseScript == "variables.a = 1")
    }
}

struct VariableRepositoryTests {
    @Test func recordsSourceAndDeletes() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let variables = VariableRepository(storage: storage)

        // Act
        try await variables.setOne(projectID: "p1", key: "host", value: "example.com")
        try await variables.setMany(
            projectID: "p1", writes: ["token": "abc"], source: .script, sourceRequestID: "r1"
        )

        // Assert
        let all = try await variables.getAll(projectID: "p1")
        #expect(all["host"]?.source == .manual)
        #expect(all["token"]?.source == .script)
        #expect(all["token"]?.sourceRequestID == "r1")
        #expect(try await variables.values(projectID: "p1") == ["host": "example.com", "token": "abc"])

        // Act
        try await variables.delete(projectID: "p1", key: "host")
        #expect(try await variables.getAll(projectID: "p1").keys.sorted() == ["token"])
    }
}
