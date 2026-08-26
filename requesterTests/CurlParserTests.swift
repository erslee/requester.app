import Foundation
import Testing
@testable import requester

/// The curl importer is the highest-risk piece of parsing in the app: it is
/// hand-rolled, and a misparse silently sends the wrong request.
struct CurlParserTests {
    @Test func parsesMethodHeadersAndJSONBody() {
        // Arrange
        let command = """
            curl -X POST 'https://api.example.com/v1/login?debug=1' \\
              -H 'Content-Type: application/json' \\
              -H "Accept: application/json" \\
              -d '{"user":"ada","password":"lovelace"}'
            """

        // Act
        let parsed = CurlParser.parse(command)

        // Assert
        #expect(parsed.method == .post)
        #expect(parsed.url == "https://api.example.com/v1/login")
        #expect(parsed.params.map(\.key) == ["debug"])
        #expect(parsed.params.first?.value == "1")
        #expect(parsed.headers.count == 2)
        #expect(parsed.bodyMode == .raw)
        #expect(parsed.rawBody == #"{"user":"ada","password":"lovelace"}"#)
        #expect(parsed.unsupported.isEmpty)
    }

    @Test func infersPostFromDataWithoutExplicitMethod() {
        // Arrange / Act
        let parsed = CurlParser.parse("curl https://example.com -d 'a=1' -d 'b=2'")

        // Assert -- form-style parts join with &, the way curl itself sends them
        #expect(parsed.method == .post)
        #expect(parsed.rawBody == "a=1&b=2")
    }

    @Test func parsesBasicAuthCookiesAndUserAgent() {
        // Arrange / Act
        let parsed = CurlParser.parse(
            "curl -u ada:lovelace -b 'a=1' -b 'b=2' -A 'Reqester/1.0' https://example.com"
        )

        // Assert -- repeated cookies collapse into one header
        #expect(parsed.auth.type == .basic)
        #expect(parsed.auth.basicUsername == "ada")
        #expect(parsed.auth.basicPassword == "lovelace")
        #expect(parsed.headers.first { $0.key == "Cookie" }?.value == "a=1; b=2")
        #expect(parsed.headers.contains { $0.key == "User-Agent" })
    }

    @Test func parsesMultipartFormFields() {
        // Arrange / Act
        let parsed = CurlParser.parse(
            "curl -F 'name=ada' -F 'avatar=@/tmp/a.png;type=image/png' https://example.com/upload"
        )

        // Assert
        #expect(parsed.bodyMode == .form)
        #expect(parsed.formFields.count == 2)
        let file = parsed.formFields.first { $0.isFile }
        #expect(file?.filePath == "/tmp/a.png")
        #expect(file?.contentType == "image/png")
    }

    /// An unmodelled flag that takes a value must not have that value mistaken
    /// for the URL -- the failure mode this list exists to prevent.
    @Test func unmodelledValueFlagDoesNotSwallowTheURL() {
        // Arrange / Act
        let parsed = CurlParser.parse("curl --max-time 30 https://example.com/real")

        // Assert
        #expect(parsed.url == "https://example.com/real")
        #expect(parsed.unsupported.contains("--max-time 30"))
    }

    @Test func supportsInlineFlagValuesAndCompressed() {
        // Arrange / Act
        let parsed = CurlParser.parse(
            "curl --request=DELETE --compressed https://example.com/thing"
        )

        // Assert
        #expect(parsed.method == .delete)
        #expect(parsed.headers.contains { $0.key == "Accept-Encoding" })
    }

    @Test func reportsMissingURL() {
        // Arrange / Act
        let parsed = CurlParser.parse("curl -X GET")

        // Assert
        #expect(parsed.url.isEmpty)
        #expect(parsed.unsupported.contains("(no URL found in command)"))
    }

    @Test(arguments: [
        ("curl https://x.com", true),
        ("  CURL -X GET https://x.com", true),
        ("https://x.com/curl", false),
        ("curlybraces", false),
    ])
    func detectsCurlCommands(input: String, expected: Bool) {
        #expect(CurlParser.looksLikeCurlCommand(input) == expected)
    }

    /// The shape Chrome produces for a GraphQL call: `--url`, many headers, and
    /// a `--data-raw $'...'` body. Previously the `$` was kept, the escapes were
    /// left undecoded, and the server answered "Unexpected token '$'".
    @Test func importsAGraphQLRequestFromAChromeStyleCommand() throws {
        // Arrange
        let command = #"""
            curl --url 'https://graphql.wnwd.com/'               -H 'content-type: application/json'               -H 'sec-ch-ua: "Not=A?Brand";v="99", "Chromium";v="151"'               --data-raw $'{"operationName":"imageryLibrary","variables":{"input":{"sceneIds":[]}},"query":"query imageryLibrary($input: ImageryLibraryInput\u0021) {\\n  imageryLibrary(input: $input) {\\n    totalCount\\n  }\\n}"}'
            """#

        // Act
        let parsed = CurlParser.parse(command)

        // Assert -- --url supplies the URL and is not reported as ignored
        #expect(parsed.url == "https://graphql.wnwd.com/")
        #expect(parsed.unsupported.isEmpty)
        #expect(parsed.method == .post)

        // Assert -- a header whose value contains quotes and commas survives whole
        #expect(parsed.headers.first { $0.key == "sec-ch-ua" }?.value
            == #""Not=A?Brand";v="99", "Chromium";v="151""#)

        // Assert -- recognised as GraphQL, so it lands in the GraphQL tab
        #expect(parsed.bodyMode == .graphQL)
        #expect(parsed.rawBody.isEmpty)

        let graphQL = try #require(parsed.graphQLBody)
        #expect(graphQL.operationName == "imageryLibrary")

        // Assert -- the query is real text with real newlines, and \u0021 is a "!"
        #expect(graphQL.query.hasPrefix("query imageryLibrary($input: ImageryLibraryInput!)"))
        #expect(graphQL.query.contains("\n"))
        #expect(!graphQL.query.contains("\\n"))
        #expect(graphQL.query.contains("totalCount"))

        // Assert -- variables come across, re-serialised readably
        #expect(graphQL.variablesJSON.contains("sceneIds"))
        let variables = try JSONSerialization.jsonObject(
            with: Data(graphQL.variablesJSON.utf8)
        ) as? [String: Any]
        #expect(variables?["input"] != nil)
    }

    /// A JSON body without a `query` is still a raw body.
    @Test func leavesAPlainJSONBodyAsRaw() {
        // Arrange / Act
        let parsed = CurlParser.parse(
            #"curl https://x.com -d '{"user":"ada","password":"lovelace"}'"#
        )

        // Assert
        #expect(parsed.bodyMode == .raw)
        #expect(parsed.graphQLBody == nil)
        #expect(parsed.rawBody == #"{"user":"ada","password":"lovelace"}"#)
    }
}
