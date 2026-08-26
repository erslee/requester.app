import Foundation
import Testing
@testable import requester

/// The in-memory backend used elsewhere approximates directory listing; these
/// pin the real filesystem behaviour the app actually runs on.
struct LocalFileStorageTests {
    private func makeStorage() throws -> (LocalFileStorage, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "reqester-fs-\(UUID().uuidString)")
        return (try LocalFileStorage(root: root), root)
    }

    @Test func createsNestedDirectoriesAndListsThem() async throws {
        // Arrange
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        // Act -- a path several levels deep, none of which exists yet
        try await storage.writeText("{}", to: "projects/p1/requests/r1.json")
        try await storage.writeText("{}", to: "projects/p1/requests/r2.json")

        // Assert
        #expect(try await storage.listDirectory(at: "projects") == ["p1"])
        #expect(try await storage.listDirectory(at: "projects/p1/requests") == ["r1.json", "r2.json"])
        #expect(await storage.exists(at: "projects/p1/requests/r1.json"))
        #expect(try await storage.readText(at: "projects/p1/requests/r1.json") == "{}")
    }

    @Test func returnsEmptyForAMissingDirectoryRatherThanThrowing() async throws {
        // Arrange
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        // Act / Assert
        #expect(try await storage.listDirectory(at: "projects").isEmpty)
        #expect(try await storage.readText(at: "nope.json") == nil)
        #expect(await storage.exists(at: "nope.json") == false)
    }

    @Test func appendsLinesToAFileItCreates() async throws {
        // Arrange
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        // Act
        try await storage.appendLine("one", to: "history/p1/2026-07.jsonl")
        try await storage.appendLine("two", to: "history/p1/2026-07.jsonl")

        // Assert -- the second append must not truncate the first
        #expect(try await storage.readText(at: "history/p1/2026-07.jsonl") == "one\ntwo\n")
    }

    @Test func deletesTreesAndSingleFiles() async throws {
        // Arrange
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        try await storage.writeText("{}", to: "projects/p1/project.json")
        try await storage.writeText("{}", to: "projects/p1/requests/r1.json")

        // Act
        try await storage.delete(at: "projects/p1/requests/r1.json")
        #expect(try await storage.listDirectory(at: "projects/p1/requests").isEmpty)

        try await storage.deleteTree(at: "projects/p1")
        #expect(try await storage.listDirectory(at: "projects").isEmpty)
    }

    /// The exact sequence the sidebar performs when a request is created.
    @Test func createsAndListsARequestThroughTheRepositories() async throws {
        // Arrange
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = ProjectRepository(storage: storage)
        let requests = RequestRepository(storage: storage)

        // Act
        let project = try await projects.create(name: "Space API")
        let request = try await requests.create(projectID: project.id)

        // Assert
        #expect(try await projects.listAll().map(\.id) == [project.id])
        #expect(try await requests.listForProject(project.id).map(\.id) == [request.id])
    }
}
