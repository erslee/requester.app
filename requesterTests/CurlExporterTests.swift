import Foundation
import Testing
@testable import requester

/// The export exists to be pasted into a terminal, so the tests that matter are
/// the ones about quoting -- and the round trip back through `CurlParser`,
/// which is what stops the two halves drifting apart.
struct CurlExporterTests {
    private func request(
        _ configure: (inout APIRequest) -> Void = { _ in }
    ) -> APIRequest {
        var request = APIRequest(id: "r1", projectID: "p1")
        request.url = "https://example.com/v1/things"
        configure(&request)
        return request
    }

    @Test func exportsMethodURLHeadersAndBody() throws {
        // Arrange
        let request = request {
            $0.method = .post
            $0.headers = [KeyValueItem(key: "X-Trace", value: "abc")]
            $0.bodyMode = .raw
            $0.rawBody = #"{"a":1}"#
        }

        // Act
        let command = try CurlExporter.command(for: request)

        // Assert
        #expect(command == """
            curl -X POST 'https://example.com/v1/things' \\
              -H 'Content-Type: application/json' \\
              -H 'X-Trace: abc' \\
              --data-raw '{"a":1}'
            """)
    }

    @Test func foldsParamsIntoTheURL() throws {
        // Arrange
        let request = request {
            $0.params = [
                KeyValueItem(key: "page", value: "2"),
                KeyValueItem(key: "skipped", value: "no", enabled: false),
            ]
        }

        // Act
        let command = try CurlExporter.command(for: request)

        // Assert -- a disabled row is not sent, so it is not exported either
        #expect(command == "curl -X GET 'https://example.com/v1/things?page=2'")
    }

    /// Auth is expanded the same way the executor expands it, so the copied
    /// command authenticates without the reader knowing which tab it came from.
    @Test func expandsAuthIntoAHeader() throws {
        // Arrange
        let request = request {
            $0.auth.type = .basic
            $0.auth.basicUsername = "user"
            $0.auth.basicPassword = "pass"
        }

        // Act
        let command = try CurlExporter.command(for: request)

        // Assert -- base64 of "user:pass"
        #expect(command.contains("-H 'Authorization: Basic dXNlcjpwYXNz'"))
    }

    @Test func exportsGraphQLAsItsJSONPayload() throws {
        // Arrange
        let request = request {
            $0.method = .post
            $0.bodyMode = .graphQL
            $0.graphQLBody = GraphQLBody(query: "{ me { id } }", variablesJSON: #"{"n":1}"#)
        }

        // Act
        let command = try CurlExporter.command(for: request)

        // Assert
        #expect(command.contains("-H 'Content-Type: application/json'"))
        #expect(command.contains(#""query":"{ me { id } }""#))
        #expect(command.contains(#""n":1"#))
    }

    /// The case single quoting cannot express directly. `'\''` closes the
    /// string, escapes one quote, and reopens -- the shell rejoins the three
    /// pieces into a single argument.
    @Test func escapesSingleQuotesInTheBody() throws {
        // Arrange
        let request = request {
            $0.method = .post
            $0.bodyMode = .raw
            $0.rawBody = #"{"note":"it's fine"}"#
        }

        // Act
        let command = try CurlExporter.command(for: request)

        // Assert
        #expect(command.hasSuffix(#"--data-raw '{"note":"it'\''s fine"}'"#))
    }

    @Test func leavesDoubleQuotesAndBackslashesAlone() {
        // Assert -- nothing inside single quotes needs escaping but a quote
        #expect(CurlExporter.singleQuoted(#"a"b\c"#) == #"'a"b\c'"#)
    }

    @Test func omitsTheBodyFlagWhenThereIsNoBody() throws {
        // Act
        let command = try CurlExporter.command(for: request { $0.method = .delete })

        // Assert
        #expect(!command.contains("--data-raw"))
        #expect(command == "curl -X DELETE 'https://example.com/v1/things'")
    }

    @Test func reportsAnUnsendableURL() {
        // Assert -- the same error Send would raise, rather than a bad command
        #expect(throws: HTTPExecutorError.self) {
            try CurlExporter.command(for: request { $0.url = "not a url" })
        }
    }

    // MARK: - Round trip

    /// Exporting and re-importing has to land on the same request, or the two
    /// halves of the feature disagree about what a command means.
    @Test func roundTripsThroughTheParser() throws {
        // Arrange
        let original = request {
            $0.method = .put
            $0.url = "https://example.com/v1/things"
            $0.params = [KeyValueItem(key: "q", value: "a b")]
            $0.headers = [
                KeyValueItem(key: "Accept", value: "application/json"),
                KeyValueItem(key: "X-Note", value: "it's here"),
            ]
            $0.bodyMode = .raw
            $0.rawBody = #"{"deep":{"s":"say \"hi\"","t":"a'b"}}"#
        }

        // Act
        let parsed = CurlParser.parse(try CurlExporter.command(for: original))

        // Assert
        #expect(parsed.unsupported.isEmpty)
        #expect(parsed.method == .put)
        #expect(parsed.url == "https://example.com/v1/things")
        #expect(parsed.params.map(\.key) == ["q"])
        #expect(parsed.params.map(\.value) == ["a b"])
        #expect(parsed.rawBody == original.rawBody)

        let exported = Dictionary(
            parsed.headers.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first }
        )
        #expect(exported["Accept"] == "application/json")
        #expect(exported["X-Note"] == "it's here")
        #expect(exported["Content-Type"] == "application/json")
    }
}
