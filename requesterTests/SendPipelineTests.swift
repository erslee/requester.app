import Foundation
import Testing
@testable import requester

/// Stubs the network at the URLSession layer, so the full pipeline -- resolve
/// variables, send, persist history to real files, run the script, persist what
/// it wrote -- can be exercised without a server.
final class StubURLProtocol: URLProtocol {
    struct Stub: Sendable {
        var statusCode: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: String = "{}"
    }

    nonisolated(unsafe) static var stub = Stub()
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
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// Serialized: the stub protocol's canned response is process-global (URLProtocol
/// is registered per-configuration but instantiated by URLSession), so running
/// these in parallel would have them overwrite each other's stub.
@Suite(.serialized)
struct SendPipelineTests {
    /// A temporary directory that is cleaned up when the test finishes.
    private func makeStorage() throws -> (LocalFileStorage, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "reqester-test-\(UUID().uuidString)")
        return (try LocalFileStorage(root: root), root)
    }

    @Test func resolvesVariablesSendsPersistsAndChainsTheToken() async throws {
        // Arrange -- a login request that reads {{host}} and writes {{token}}
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        StubURLProtocol.stub = .init(body: #"{"access_token":"tok-42"}"#)

        let variables = VariableRepository(storage: storage)
        let history = HistoryRepository(storage: storage)
        let requests = RequestRepository(storage: storage)
        let service = HistoryService(
            executor: HTTPExecutor(session: StubURLProtocol.session()),
            history: history,
            variables: variables,
            projects: ProjectRepository(storage: storage),
            scripts: ScriptRunner()
        )

        let project = try await ProjectRepository(storage: storage).create(name: "Test")
        try await variables.setOne(projectID: project.id, key: "host", value: "api.example.com")

        var request = try await requests.create(projectID: project.id, name: "Login")
        request.method = .post
        request.url = "https://{{host}}/login"
        request.bodyMode = .raw
        request.rawBody = #"{"user":"ada"}"#
        request.headers = [KeyValueItem(key: "X-Trace", value: "t-1")]
        request.postResponseScript = "variables.token = response.json().access_token"
        request = try await requests.save(request)

        // Act
        let entry = try await service.sendAndRecord(request)

        // Assert -- the variable was substituted before sending
        #expect(entry.resolvedURL == "https://api.example.com/login")
        #expect(StubURLProtocol.lastRequest?.url?.host() == "api.example.com")
        #expect(entry.response?.statusCode == 200)
        #expect(entry.error == nil)

        // Assert -- the snapshot keeps the unresolved template, so it stays editable
        #expect(entry.requestSnapshot.url == "https://{{host}}/login")

        // Assert -- the script ran and its write became a project variable
        #expect(entry.scriptResult?.succeeded == true)
        #expect(entry.scriptResult?.variablesWritten == ["token": "tok-42"])
        #expect(try await variables.getAll(projectID: project.id)["token"]?.source == .script)

        // Assert -- one reconciled entry on disk, carrying the script result
        let stored = try await history.listAll(projectID: project.id)
        #expect(stored.count == 1)
        #expect(stored.first?.scriptResult?.variablesWritten == ["token": "tok-42"])

        // Assert -- the JSONL file is where the layout says it should be
        let monthKey = HistoryRepository.monthKey(for: entry.sentAt)
        #expect(await storage.exists(at: "history/\(project.id)/\(monthKey).jsonl"))
    }

    /// Global headers live on the project, so the request keeps its own copy
    /// free of them -- but what goes over the wire has them merged in.
    @Test func inheritsProjectHeadersUnlessTheRequestOverridesThem() async throws {
        // Arrange -- three global headers, one of which the request names itself
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        StubURLProtocol.stub = .init()

        let projects = ProjectRepository(storage: storage)
        let variables = VariableRepository(storage: storage)
        let requests = RequestRepository(storage: storage)
        let service = HistoryService(
            executor: HTTPExecutor(session: StubURLProtocol.session()),
            history: HistoryRepository(storage: storage),
            variables: variables,
            projects: projects,
            scripts: ScriptRunner()
        )

        let project = try await projects.create(name: "Test")
        try await variables.setOne(projectID: project.id, key: "key", value: "sekret")
        _ = try await projects.setGlobalHeaders(
            [
                KeyValueItem(key: "X-Api-Key", value: "{{key}}"),
                KeyValueItem(key: "Accept", value: "application/json"),
                KeyValueItem(key: "X-Off", value: "no", enabled: false),
            ],
            for: project.id
        )

        var request = try await requests.create(projectID: project.id, name: "List")
        request.url = "https://example.com/items"
        request.headers = [KeyValueItem(key: "accept", value: "text/csv")]
        request = try await requests.save(request)

        // Act
        let entry = try await service.sendAndRecord(request)

        // Assert -- inherited, with its {{variable}} resolved like any other field
        let sent = StubURLProtocol.lastRequest
        #expect(sent?.value(forHTTPHeaderField: "X-Api-Key") == "sekret")
        // Assert -- the request's own value wins, whatever the casing
        #expect(sent?.value(forHTTPHeaderField: "Accept") == "text/csv")
        // Assert -- a switched-off global header is never sent
        #expect(sent?.value(forHTTPHeaderField: "X-Off") == nil)

        // Assert -- neither the snapshot nor the saved request grew a copy of
        // the project's headers
        #expect(entry.requestSnapshot.headers.map(\.key) == ["accept"])
        let saved = try await requests.get(projectID: project.id, requestID: request.id)
        #expect(saved?.headers.map(\.key) == ["accept"])
    }

    @Test func recordsAFailedSendWithAnErrorInsteadOfLosingIt() async throws {
        // Arrange -- a URL that cannot be built at all
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        let history = HistoryRepository(storage: storage)
        let service = HistoryService(
            executor: HTTPExecutor(session: StubURLProtocol.session()),
            history: history,
            variables: VariableRepository(storage: storage),
            projects: ProjectRepository(storage: storage),
            scripts: ScriptRunner()
        )

        var request = APIRequest(id: "r1", projectID: "p1")
        request.url = "not a url"

        // Act
        let entry = try await service.sendAndRecord(request)

        // Assert -- a failure is still a history record, just without a response
        #expect(entry.response == nil)
        #expect(entry.error != nil)
        #expect(try await history.listAll(projectID: "p1").count == 1)
    }

    @Test func keepsTheResponseWhenTheScriptFails() async throws {
        // Arrange
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        StubURLProtocol.stub = .init(statusCode: 201, body: #"{"id":7}"#)

        let history = HistoryRepository(storage: storage)
        let variables = VariableRepository(storage: storage)
        let service = HistoryService(
            executor: HTTPExecutor(session: StubURLProtocol.session()),
            history: history,
            variables: variables,
            projects: ProjectRepository(storage: storage),
            scripts: ScriptRunner()
        )

        var request = APIRequest(id: "r1", projectID: "p1")
        request.url = "https://example.com/create"
        request.postResponseScript = "throw new Error('boom')"

        // Act
        let entry = try await service.sendAndRecord(request)

        // Assert -- the response survives a broken script
        #expect(entry.response?.statusCode == 201)
        #expect(entry.scriptResult?.succeeded == false)
        #expect(try await variables.getAll(projectID: "p1").isEmpty)
    }

    /// The size limit trims what is written to the history file, not what the
    /// caller gets back -- the panel must show the whole response.
    @Test func returnsTheWholeBodyEvenWhenTheStoredCopyIsTrimmed() async throws {
        // Arrange -- a body well past the trim threshold
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        let wholeBody = String(repeating: "abcdefghij", count: 5_000)   // 50,000 chars
        StubURLProtocol.stub = .init(body: wholeBody)

        let history = HistoryRepository(storage: storage, bodyTruncateBytes: 1_000)
        let service = HistoryService(
            executor: HTTPExecutor(session: StubURLProtocol.session()),
            history: history,
            variables: VariableRepository(storage: storage),
            projects: ProjectRepository(storage: storage),
            scripts: ScriptRunner()
        )

        var request = APIRequest(id: "r1", projectID: "p1")
        request.url = "https://example.com/big"

        // Act
        let entry = try await service.sendAndRecord(request)

        // Assert -- what comes back is complete and not flagged as trimmed
        #expect(entry.response?.bodyText.count == wholeBody.count)
        #expect(entry.response?.bodyTruncated == false)

        // Assert -- what went to disk is trimmed, with the rest in a blob
        let stored = try await history.listAll(projectID: "p1")
        #expect(stored.count == 1)
        #expect(stored.first?.response?.bodyTruncated == true)
        #expect(stored.first?.response?.bodyText.count == 1_000)
        #expect(try await history.fullBody(for: stored[0])?.count == wholeBody.count)
    }

    /// A script amendment must not write the trimmed body back in full, or the
    /// history file would grow by the whole response on every scripted send.
    @Test func aScriptAmendmentKeepsTheStoredBodyTrimmed() async throws {
        // Arrange
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        StubURLProtocol.stub = .init(body: String(repeating: "x", count: 20_000))

        let history = HistoryRepository(storage: storage, bodyTruncateBytes: 1_000)
        let service = HistoryService(
            executor: HTTPExecutor(session: StubURLProtocol.session()),
            history: history,
            variables: VariableRepository(storage: storage),
            projects: ProjectRepository(storage: storage),
            scripts: ScriptRunner()
        )

        var request = APIRequest(id: "r1", projectID: "p1")
        request.url = "https://example.com/big"
        request.postResponseScript = "variables.size = response.text.length"

        // Act
        let entry = try await service.sendAndRecord(request)

        // Assert -- the caller still sees everything, including the script result
        #expect(entry.response?.bodyText.count == 20_000)
        #expect(entry.scriptResult?.variablesWritten["size"] == "20000")

        // Assert -- and the stored copy is still the trimmed one
        let stored = try await history.listAll(projectID: "p1")
        #expect(stored.count == 1)
        #expect(stored.first?.response?.bodyText.count == 1_000)
        #expect(stored.first?.scriptResult?.succeeded == true)
    }
}
