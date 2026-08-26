import Foundation
import Testing
@testable import requester

/// Stubs document fetching, separately from `StubURLProtocol`.
///
/// The canned response has to live in a static, because `URLSession`
/// instantiates the protocol itself. `.serialized` keeps tests *within* a suite
/// from overlapping, but not two suites from running at once -- so sharing one
/// stub with `SendPipelineTests` had the two clobbering each other's response
/// whenever the whole target ran. Separate storage, no ordering to rely on.
final class SpecStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stub = StubURLProtocol.Stub()
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: Self.stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpecStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// The whole sync against real storage and a stubbed network: fetch, parse,
/// plan, write, and what a second run does to the first run's output.
///
/// Serialized because the stub above is process-global within this suite.
@Suite(.serialized)
struct SpecSyncPipelineTests {
    private func makeStorage() throws -> (LocalFileStorage, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "requester-spec-test-\(UUID().uuidString)")
        return (try LocalFileStorage(root: root), root)
    }

    private func service(storage: some StorageBackend) -> SpecSyncService {
        SpecSyncService(
            requests: RequestRepository(storage: storage),
            projects: ProjectRepository(storage: storage),
            variables: VariableRepository(storage: storage),
            fetcher: SpecFetcher(session: SpecStubURLProtocol.session())
        )
    }

    private func spec(paths: String) -> String {
        """
        {
          "openapi": "3.0.0",
          "info": { "title": "Acme" },
          "servers": [{ "url": "https://api.acme.dev" }],
          "paths": { \(paths) }
        }
        """
    }

    private var twoEndpoints: String {
        """
        "/pets": { "get": { "operationId": "listPets", "summary": "List pets" } },
        "/orders": { "get": { "operationId": "listOrders", "summary": "List orders" } }
        """
    }

    // MARK: - First import

    @Test func fetchesParsesAndWritesEveryEndpoint() async throws {
        // Arrange
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        let projects = ProjectRepository(storage: storage)
        let project = try await projects.create(name: "Acme")
        var source = SpecSource(kind: .url)
        source.url = "https://api.acme.dev/openapi.json"
        _ = try await projects.setSpecSource(source, for: project.id)

        SpecStubURLProtocol.stub = .init(body: spec(paths: twoEndpoints))

        // Act
        let summary = try await service(storage: storage).sync(projectID: project.id, using: .saved)

        // Assert
        #expect(summary.added == 2)
        #expect(summary.title == "Acme")

        let written = try await RequestRepository(storage: storage).listForProject(project.id)
        #expect(written.count == 2)
        #expect(written.allSatisfy { $0.spec != nil })
        #expect(written.map(\.url).allSatisfy { $0.hasPrefix("{{baseUrl}}") })

        // And the server URL landed in the variable those URLs point at
        let values = try await VariableRepository(storage: storage).values(projectID: project.id)
        #expect(values["baseUrl"] == "https://api.acme.dev")

        // The source now records when it was read
        #expect(try await projects.get(project.id)?.specSource?.lastSyncedAt != nil)
    }

    @Test func sendsResolvedHeadersAndURLWhenFetching() async throws {
        // Arrange -- a spec behind a token, reached with the project's own values
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        let projects = ProjectRepository(storage: storage)
        let project = try await projects.create(name: "Acme")
        try await VariableRepository(storage: storage).setMany(
            projectID: project.id,
            writes: ["host": "https://specs.acme.dev", "token": "s3cret"],
            source: .manual
        )
        var source = SpecSource(kind: .url)
        source.url = "{{host}}/openapi.json"
        source.headers = [KeyValueItem(key: "Authorization", value: "Bearer {{token}}")]
        _ = try await projects.setSpecSource(source, for: project.id)

        SpecStubURLProtocol.stub = .init(body: spec(paths: twoEndpoints))

        // Act
        _ = try await service(storage: storage).sync(projectID: project.id, using: .saved)

        // Assert
        let sent = try #require(SpecStubURLProtocol.lastRequest)
        #expect(sent.url?.absoluteString == "https://specs.acme.dev/openapi.json")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer s3cret")
    }

    // MARK: - Re-sync

    @Test func aSecondRunAddsRemovesAndKeepsWork() async throws {
        // Arrange -- import, then make one of the requests the user's own
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        let projects = ProjectRepository(storage: storage)
        let requests = RequestRepository(storage: storage)
        let project = try await projects.create(name: "Acme")
        var source = SpecSource(kind: .url)
        source.url = "https://api.acme.dev/openapi.json"
        _ = try await projects.setSpecSource(source, for: project.id)
        let service = service(storage: storage)

        SpecStubURLProtocol.stub = .init(body: spec(paths: twoEndpoints))
        _ = try await service.sync(projectID: project.id, using: .saved)

        var pets = try #require(
            try await requests.listForProject(project.id)
                .first { $0.spec?.key == "operationId:listPets" }
        )
        pets.name = "My pets"
        pets.postResponseScript = "variables.first = response.json()[0].id"
        pets.auth.type = .bearer
        pets.auth.bearerToken = "{{token}}"
        _ = try await requests.save(pets)

        // Act -- /orders is gone, /invoices is new
        SpecStubURLProtocol.stub = .init(body: spec(paths: """
            "/pets": { "get": { "operationId": "listPets", "summary": "List pets" } },
            "/invoices": { "get": { "operationId": "listInvoices", "summary": "List invoices" } }
            """))
        let summary = try await service.sync(projectID: project.id, using: .saved)

        // Assert
        #expect(summary.added == 1)
        #expect(summary.removed == 1)

        let after = try await requests.listForProject(project.id)
        #expect(after.count == 3, "a removed endpoint is kept, not deleted")

        let orders = try #require(after.first { $0.spec?.key == "operationId:listOrders" })
        #expect(orders.spec?.isRemoved == true)
        #expect(orders.url == "{{baseUrl}}/orders", "and it stays usable")

        let keptWork = try #require(after.first { $0.spec?.key == "operationId:listPets" })
        #expect(keptWork.name == "My pets")
        #expect(keptWork.postResponseScript == "variables.first = response.json()[0].id")
        #expect(keptWork.auth.bearerToken == "{{token}}")
    }

    @Test func aReturningEndpointIsRestoredRatherThanDuplicated() async throws {
        // Arrange
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        let projects = ProjectRepository(storage: storage)
        let requests = RequestRepository(storage: storage)
        let project = try await projects.create(name: "Acme")
        var source = SpecSource(kind: .url)
        source.url = "https://api.acme.dev/openapi.json"
        _ = try await projects.setSpecSource(source, for: project.id)
        let service = service(storage: storage)

        SpecStubURLProtocol.stub = .init(body: spec(paths: twoEndpoints))
        _ = try await service.sync(projectID: project.id, using: .saved)
        let originalID = try #require(
            try await requests.listForProject(project.id)
                .first { $0.spec?.key == "operationId:listOrders" }?.id
        )

        // Act -- drop it, then bring it back
        SpecStubURLProtocol.stub = .init(body: spec(paths: """
            "/pets": { "get": { "operationId": "listPets", "summary": "List pets" } }
            """))
        _ = try await service.sync(projectID: project.id, using: .saved)

        SpecStubURLProtocol.stub = .init(body: spec(paths: twoEndpoints))
        let summary = try await service.sync(projectID: project.id, using: .saved)

        // Assert
        #expect(summary.restored == 1)
        #expect(summary.added == 0)

        let after = try await requests.listForProject(project.id)
        #expect(after.count == 2)
        let orders = try #require(after.first { $0.spec?.key == "operationId:listOrders" })
        #expect(orders.id == originalID, "the same request, not a second one")
        #expect(orders.spec?.isRemoved == false)
    }

    @Test func syncingAnUnchangedDocumentWritesNothing() async throws {
        // Arrange
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        let projects = ProjectRepository(storage: storage)
        let project = try await projects.create(name: "Acme")
        var source = SpecSource(kind: .url)
        source.url = "https://api.acme.dev/openapi.json"
        _ = try await projects.setSpecSource(source, for: project.id)
        let service = service(storage: storage)

        SpecStubURLProtocol.stub = .init(body: spec(paths: twoEndpoints))
        _ = try await service.sync(projectID: project.id, using: .saved)

        // Act
        let summary = try await service.sync(projectID: project.id, using: .saved)

        // Assert
        #expect(summary.hasChanges == false)
        #expect(summary.unchanged == 2)
    }

    /// A hand-written request in a spec-backed project must survive a sync
    /// untouched -- it was never in the document, so it cannot have left it.
    @Test func aHandMadeRequestIsNotTombstoned() async throws {
        // Arrange
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        let projects = ProjectRepository(storage: storage)
        let requests = RequestRepository(storage: storage)
        let project = try await projects.create(name: "Acme")
        var source = SpecSource(kind: .url)
        source.url = "https://api.acme.dev/openapi.json"
        _ = try await projects.setSpecSource(source, for: project.id)

        var mine = try await requests.create(projectID: project.id, name: "My ping")
        mine.url = "https://api.acme.dev/ping"
        _ = try await requests.save(mine)

        SpecStubURLProtocol.stub = .init(body: spec(paths: twoEndpoints))

        // Act
        _ = try await service(storage: storage).sync(projectID: project.id, using: .saved)

        // Assert
        let after = try await requests.listForProject(project.id)
        let ping = try #require(after.first { $0.id == mine.id })
        #expect(ping.spec == nil)
        #expect(ping.name == "My ping")
        #expect(ping.url == "https://api.acme.dev/ping")
    }

    /// Pointing the project at staging must survive every later refresh.
    @Test func anEditedBaseURLIsNotResetByARefresh() async throws {
        // Arrange
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        let projects = ProjectRepository(storage: storage)
        let variables = VariableRepository(storage: storage)
        let project = try await projects.create(name: "Acme")
        var source = SpecSource(kind: .url)
        source.url = "https://api.acme.dev/openapi.json"
        _ = try await projects.setSpecSource(source, for: project.id)
        let service = service(storage: storage)

        SpecStubURLProtocol.stub = .init(body: spec(paths: twoEndpoints))
        _ = try await service.sync(projectID: project.id, using: .saved)

        // Act
        try await variables.setOne(
            projectID: project.id, key: "baseUrl", value: "https://staging.acme.dev"
        )
        _ = try await service.sync(projectID: project.id, using: .saved)

        // Assert
        #expect(try await variables.values(projectID: project.id)["baseUrl"]
            == "https://staging.acme.dev")
    }

    // MARK: - Failures leave things alone

    @Test func aFailedFetchChangesNothing() async throws {
        // Arrange
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        let projects = ProjectRepository(storage: storage)
        let requests = RequestRepository(storage: storage)
        let project = try await projects.create(name: "Acme")
        var source = SpecSource(kind: .url)
        source.url = "https://api.acme.dev/openapi.json"
        _ = try await projects.setSpecSource(source, for: project.id)
        let service = service(storage: storage)

        SpecStubURLProtocol.stub = .init(body: spec(paths: twoEndpoints))
        _ = try await service.sync(projectID: project.id, using: .saved)
        let before = try await requests.listForProject(project.id)

        // Act -- the server answers 500
        SpecStubURLProtocol.stub = .init(statusCode: 500, body: "nope")
        await #expect(throws: SpecFetchError.self) {
            _ = try await service.sync(projectID: project.id, using: .saved)
        }

        // Assert
        #expect(try await requests.listForProject(project.id) == before)
    }

    @Test func aDocumentThatFailsToParseChangesNothing() async throws {
        // Arrange
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        let projects = ProjectRepository(storage: storage)
        let requests = RequestRepository(storage: storage)
        let project = try await projects.create(name: "Acme")
        var source = SpecSource(kind: .url)
        source.url = "https://api.acme.dev/openapi.json"
        _ = try await projects.setSpecSource(source, for: project.id)
        let service = service(storage: storage)

        SpecStubURLProtocol.stub = .init(body: spec(paths: twoEndpoints))
        _ = try await service.sync(projectID: project.id, using: .saved)
        let before = try await requests.listForProject(project.id)

        // Act -- the endpoint starts serving the Swagger UI page instead
        SpecStubURLProtocol.stub = .init(body: "<!doctype html><html>Swagger UI</html>")
        await #expect(throws: SpecImportError.self) {
            _ = try await service.sync(projectID: project.id, using: .saved)
        }

        // Assert
        #expect(try await requests.listForProject(project.id) == before)
    }

    /// A file-backed source has nothing to re-fetch, and must say so rather than
    /// failing obscurely.
    @Test func refreshingAFileSourceAsksForAReupload() async throws {
        // Arrange
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        let projects = ProjectRepository(storage: storage)
        let project = try await projects.create(name: "Acme")
        _ = try await projects.setSpecSource(SpecSource(kind: .file), for: project.id)

        // Act / Assert
        await #expect(throws: SpecSyncError.self) {
            _ = try await service(storage: storage).sync(projectID: project.id, using: .saved)
        }
    }

    // MARK: - Uploading

    @Test func anUploadedFileGoesThroughTheSameMergePath() async throws {
        // Arrange
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        let projects = ProjectRepository(storage: storage)
        let requests = RequestRepository(storage: storage)
        let project = try await projects.create(name: "Acme")
        let service = service(storage: storage)

        let first = root.appending(path: "openapi.json")
        try Data(spec(paths: twoEndpoints).utf8).write(to: first)
        _ = try await projects.setSpecSource(SpecSource(kind: .file), for: project.id)
        _ = try await service.sync(projectID: project.id, using: .file(first))

        // Act -- re-upload a document with one endpoint dropped and one added
        let second = root.appending(path: "openapi-v2.json")
        try Data(spec(paths: """
            "/pets": { "get": { "operationId": "listPets", "summary": "List pets" } },
            "/invoices": { "get": { "operationId": "listInvoices", "summary": "List invoices" } }
            """).utf8).write(to: second)
        let summary = try await service.sync(projectID: project.id, using: .file(second))

        // Assert -- identical outcome to a link refresh
        #expect(summary.added == 1)
        #expect(summary.removed == 1)
        #expect(try await requests.listForProject(project.id).count == 3)
        #expect(try await projects.get(project.id)?.specSource?.fileName == "openapi-v2.json")
    }
}
