import Foundation
import Testing
@testable import requester

/// What ends up in the `URLRequest` is what the server sees, so body encoding
/// and auth placement are worth pinning down.
struct RequestBuildingTests {
    private func request(url: String = "https://example.com/path") -> APIRequest {
        var request = APIRequest(id: "r1", projectID: "p1")
        request.url = url
        return request
    }

    @Test func keepsAQueryTypedIntoTheURLWhenThereAreNoParams() throws {
        // Arrange
        let request = request(url: "https://example.com/path?existing=1")

        // Act
        let built = try HTTPExecutor.buildURLRequest(from: request)

        // Assert -- an empty params table must not wipe the URL's own query
        #expect(built.url?.query() == "existing=1")
    }

    @Test func replacesTheQueryWhenParamsArePresent() throws {
        // Arrange
        var request = request(url: "https://example.com/path?existing=1")
        request.params = [
            KeyValueItem(key: "a", value: "1"),
            KeyValueItem(key: "skipped", value: "x", enabled: false),
        ]

        // Act
        let built = try HTTPExecutor.buildURLRequest(from: request)

        // Assert -- disabled rows are not sent
        #expect(built.url?.query() == "a=1")
    }

    @Test func encodesRawFormAndGraphQLBodies() throws {
        // Arrange -- raw
        var raw = request()
        raw.method = .post
        raw.bodyMode = .raw
        raw.rawBody = #"{"a":1}"#

        // Act / Assert
        var built = try HTTPExecutor.buildURLRequest(from: raw)
        #expect(built.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(built.httpBody == Data(#"{"a":1}"#.utf8))

        // Arrange -- form
        var form = request()
        form.method = .post
        form.bodyMode = .form
        form.formFields = [
            FormField(key: "a", value: "1"),
            FormField(key: "file", isFile: true, filePath: "/tmp/x"),
        ]

        // Act / Assert -- file fields are not encoded into the body
        built = try HTTPExecutor.buildURLRequest(from: form)
        #expect(
            built.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded"
        )
        #expect(String(decoding: built.httpBody ?? Data(), as: UTF8.self) == "a=1")

        // Arrange -- GraphQL
        var graphQL = request()
        graphQL.method = .post
        graphQL.bodyMode = .graphQL
        graphQL.graphQLBody = GraphQLBody(query: "{ me }", variablesJSON: #"{"id":1}"#)

        // Act / Assert
        built = try HTTPExecutor.buildURLRequest(from: graphQL)
        let payload = try JSONSerialization.jsonObject(
            with: built.httpBody ?? Data()
        ) as? [String: Any]
        #expect(payload?["query"] as? String == "{ me }")
        #expect((payload?["variables"] as? [String: Any])?["id"] as? Int == 1)
    }

    @Test func placesEachAuthKindWhereItBelongs() throws {
        // Arrange -- basic
        var basic = request()
        basic.auth.type = .basic
        basic.auth.basicUsername = "ada"
        basic.auth.basicPassword = "lovelace"

        // Act / Assert -- encoded up front so it shows in the recorded headers
        var built = try HTTPExecutor.buildURLRequest(from: basic)
        #expect(
            built.value(forHTTPHeaderField: "Authorization")
                == "Basic \(Data("ada:lovelace".utf8).base64EncodedString())"
        )

        // Arrange -- bearer
        var bearer = request()
        bearer.auth.type = .bearer
        bearer.auth.bearerToken = "abc"

        // Act / Assert
        built = try HTTPExecutor.buildURLRequest(from: bearer)
        #expect(built.value(forHTTPHeaderField: "Authorization") == "Bearer abc")

        // Arrange -- API key in a query parameter
        var apiKey = request()
        apiKey.auth.type = .apiKey
        apiKey.auth.apiKeyName = "key"
        apiKey.auth.apiKeyValue = "secret"
        apiKey.auth.apiKeyIn = .query

        // Act / Assert
        built = try HTTPExecutor.buildURLRequest(from: apiKey)
        #expect(built.url?.query()?.contains("key=secret") == true)
    }

    @Test func rejectsAnEmptyURLWithAReadableMessage() {
        // Arrange / Act / Assert
        #expect(throws: HTTPExecutorError.self) {
            try HTTPExecutor.buildURLRequest(from: request(url: "   "))
        }
    }

    @Test func derivesADisplayNameFromTheURL() {
        // Assert -- host plus the last path segment
        #expect(RequestNaming.derivedName(fromURL: "https://api.example.com/v1/users")
            == "api.example.com/users")
        #expect(RequestNaming.derivedName(fromURL: "https://api.example.com") == "api.example.com")
        #expect(RequestNaming.derivedName(fromURL: "https://swapi.info/api/") == "swapi.info/api")

        // Assert -- query and fragment are not part of the name
        #expect(RequestNaming.derivedName(fromURL: "https://x.com/a/b?q=1") == "x.com/b")
        #expect(RequestNaming.derivedName(fromURL: "https://x.com/a/b#frag") == "x.com/b")

        // Assert -- a scheme is optional
        #expect(RequestNaming.derivedName(fromURL: "swapi.info/planets") == "swapi.info/planets")

        // Assert -- nothing to go on falls back
        #expect(RequestNaming.derivedName(fromURL: "") == RequestNaming.fallback)
        #expect(RequestNaming.derivedName(fromURL: "https://") == RequestNaming.fallback)
    }

    /// `URLComponents` rejects curly braces in a host, so a templated URL used
    /// to fall through to "Untitled Request" -- which is every unsent request
    /// in a project that uses a `{{domain}}` variable.
    @Test func namesATemplatedURLBeforeAndAfterResolving() {
        // Arrange
        let templated = "https://{{domain}}/api/planets"

        // Act / Assert -- readable even unresolved
        #expect(RequestNaming.derivedName(fromURL: templated) == "{{domain}}/planets")

        // Act / Assert -- and the real host once the variable is known
        let resolved = VariableResolver.resolve(templated, with: ["domain": "swapi.info"])
        #expect(RequestNaming.derivedName(fromURL: resolved) == "swapi.info/planets")
    }

    @Test func anExplicitNameWinsOverTheDerivedOne() {
        // Arrange
        var request = APIRequest(id: "r1", projectID: "p1")
        request.url = "https://example.com/x"

        // Act / Assert
        #expect(RequestNaming.displayName(for: request) == "example.com/x")
        request.name = "Login"
        #expect(RequestNaming.displayName(for: request) == "Login")
    }

    /// Saving only the name bumps `updatedAt`; if that counted as a change the
    /// request would read as permanently unsaved.
    @Test func dirtinessIgnoresTimestampsAndBlankRows() {
        // Arrange
        var saved = APIRequest(id: "r1", projectID: "p1")
        saved.url = "https://example.com"
        var draft = saved
        draft.updatedAt = saved.updatedAt.addingTimeInterval(60)
        draft.params = [KeyValueItem()]          // the editor's trailing blank row
        draft.headers = [KeyValueItem()]

        // Assert -- neither the timestamp nor the placeholder rows are changes
        #expect(draft.editableContent == saved.editableContent)

        // Act -- a real edit
        draft.params = [KeyValueItem(key: "a", value: "1")]

        // Assert
        #expect(draft.editableContent != saved.editableContent)
    }
}
