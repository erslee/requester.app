import Testing
@testable import requester

/// The script runner is what makes auth-token chaining work, and a hung script
/// must not be able to take the app with it.
struct ScriptRunnerTests {
    private func response(body: String, status: Int = 200) -> ResponseRecord {
        var record = ResponseRecord(statusCode: status)
        record.bodyText = body
        record.headers = [KeyValueItem(key: "content-type", value: "application/json")]
        return record
    }

    @Test func writesVariablesFromAParsedResponse() async {
        // Arrange
        let runner = ScriptRunner()
        let source = "variables.token = response.json().access_token"

        // Act
        let result = await runner.run(
            source: source,
            response: response(body: #"{"access_token":"abc123"}"#),
            timeoutSeconds: 5
        )

        // Assert
        #expect(result.ran)
        #expect(result.succeeded)
        #expect(result.variablesWritten == ["token": "abc123"])
    }

    @Test func exposesStatusHeadersAndCapturesConsoleOutput() async {
        // Arrange
        let source = """
            console.log("status", response.statusCode);
            variables.contentType = response.headers["content-type"];
            variables.length = response.text.length;
            """

        // Act
        let result = await ScriptRunner().run(
            source: source, response: response(body: "{}"), timeoutSeconds: 5
        )

        // Assert -- non-string values are stringified, since that is what gets sent
        #expect(result.succeeded)
        #expect(result.variablesWritten["contentType"] == "application/json")
        #expect(result.variablesWritten["length"] == "2")
        #expect(result.output.contains("status"))
    }

    @Test func reportsAThrownErrorWithoutFailingTheSend() async {
        // Arrange / Act
        let result = await ScriptRunner().run(
            source: "throw new Error('nope')", response: response(body: "{}"), timeoutSeconds: 5
        )

        // Assert
        #expect(result.ran)
        #expect(!result.succeeded)
        #expect(result.error?.contains("nope") == true)
    }

    @Test func reportsAParseFailureOnAnEmptyBody() async {
        // Arrange / Act -- json() on a non-JSON body should surface, not crash
        let result = await ScriptRunner().run(
            source: "variables.x = response.json().a", response: response(body: "not json"),
            timeoutSeconds: 5
        )

        // Assert
        #expect(!result.succeeded)
        #expect(result.error != nil)
    }

    @Test func doesNotRunAnEmptyScript() async {
        // Arrange / Act
        let result = await ScriptRunner().run(
            source: "   \n  ", response: response(body: "{}"), timeoutSeconds: 5
        )

        // Assert
        #expect(!result.ran)
    }

    @Test(.timeLimit(.minutes(1)))
    func timesOutAnInfiniteLoopInsteadOfHanging() async {
        // Arrange / Act
        let result = await ScriptRunner().run(
            source: "while (true) {}", response: response(body: "{}"), timeoutSeconds: 1
        )

        // Assert
        #expect(result.ran)
        #expect(!result.succeeded)
        #expect(result.error?.contains("timed out") == true)
    }
}
