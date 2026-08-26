import Testing
@testable import requester

/// Variable resolution decides what actually goes over the wire, so both the
/// substitution and the deliberate non-substitution matter.
struct VariableResolverTests {
    @Test func substitutesKnownNamesAndLeavesUnknownOnesLiteral() {
        // Arrange
        let variables = ["host": "api.example.com", "token": "abc123"]

        // Act
        let resolved = VariableResolver.resolve(
            "https://{{host}}/v1?t={{ token }}&x={{missing}}", with: variables
        )

        // Assert -- an unknown name stays visible rather than becoming empty
        #expect(resolved == "https://api.example.com/v1?t=abc123&x={{missing}}")
    }

    @Test func resolvesAcrossEveryRequestField() {
        // Arrange
        var request = APIRequest(id: "r1", projectID: "p1")
        request.url = "https://{{host}}/login"
        request.params = [KeyValueItem(key: "v", value: "{{version}}")]
        request.headers = [KeyValueItem(key: "X-{{header}}", value: "{{token}}")]
        request.rawBody = #"{"key":"{{token}}"}"#
        request.formFields = [
            FormField(key: "text", value: "{{token}}"),
            FormField(key: "file", isFile: true, filePath: "/tmp/{{token}}"),
        ]
        request.graphQLBody = GraphQLBody(
            query: "{ user(id: \"{{userID}}\") }", variablesJSON: #"{"id":"{{userID}}"}"#
        )
        request.auth.bearerToken = "{{token}}"

        let variables = [
            "host": "example.com", "version": "2", "header": "Trace",
            "token": "abc", "userID": "42",
        ]

        // Act
        let resolved = VariableResolver.resolve(request, with: variables)

        // Assert
        #expect(resolved.url == "https://example.com/login")
        #expect(resolved.params.first?.value == "2")
        #expect(resolved.headers.first?.key == "X-Trace")
        #expect(resolved.headers.first?.value == "abc")
        #expect(resolved.rawBody == #"{"key":"abc"}"#)
        #expect(resolved.formFields[0].value == "abc")
        // A file field's value is a path, not a template, so it is left alone.
        #expect(resolved.formFields[1].filePath == "/tmp/{{token}}")
        #expect(resolved.graphQLBody?.query == "{ user(id: \"42\") }")
        #expect(resolved.auth.bearerToken == "abc")
    }

    @Test func findsNamesForHighlighting() {
        #expect(VariableResolver.names(in: "{{a}} and {{ b_1.c-d }}") == ["a", "b_1.c-d"])
        #expect(VariableResolver.names(in: "no variables here").isEmpty)
    }

    @Test func classifiesMixedTextAsInvalid() {
        // A mix must read as invalid: that is the actionable signal.
        #expect(VariableStatus.classify("{{a}}{{b}}", knownNames: ["a"]) == .invalid)
        #expect(VariableStatus.classify("{{a}}", knownNames: ["a"]) == .valid)
        #expect(VariableStatus.classify("plain", knownNames: []) == .none)
    }
}
