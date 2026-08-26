import AppKit
import Testing
@testable import requester

/// Highlighting is layered: each pass overwrites the last, so the order decides
/// whether a keyword inside a string or a comment gets coloured as one.
struct SyntaxHighlighterTests {
    /// Flattens the spans the way the text view does, so what is asserted is
    /// what would actually be drawn.
    private func painted(
        _ line: String, options: SyntaxHighlighter.Options
    ) -> [(String, NSColor)] {
        let text = line as NSString
        var colors = [NSColor?](repeating: nil, count: text.length)
        for span in SyntaxHighlighter.spans(in: line, options: options) {
            for index in span.range.location..<NSMaxRange(span.range) {
                colors[index] = span.color
            }
        }

        var runs: [(String, NSColor)] = []
        var start = 0
        while start < text.length {
            var end = start + 1
            while end < text.length, colors[end] == colors[start] { end += 1 }
            if let color = colors[start] {
                runs.append(
                    (text.substring(with: NSRange(location: start, length: end - start)), color)
                )
            }
            start = end
        }
        return runs
    }

    private let graphQL = SyntaxHighlighter.Options(graphQL: true)

    @Test func coloursGraphQLOperationsTypesAndVariables() {
        // Arrange / Act
        let runs = painted(
            "query imageryLibrary($input: ImageryLibraryInput!) {", options: graphQL
        )

        // Assert
        #expect(runs.map(\.0) == ["query", "$input", "ImageryLibraryInput"])
        #expect(runs[0].1 == .jsonKeyword)
        #expect(runs[1].1 == .graphQLVariable)
        #expect(runs[2].1 == .graphQLType)
    }

    /// `input`, `type` and `union` are schema-definition words but ordinary
    /// argument names in a query -- colouring them as keywords is misleading.
    @Test func leavesArgumentNamesThatLookLikeKeywordsAlone() {
        // Arrange / Act
        let runs = painted("  imageryLibrary(input: $input, type: 3) {", options: graphQL)

        // Assert -- only the variable and the number are coloured
        #expect(runs.map(\.0) == ["$input", "3"])
    }

    @Test func coloursDirectivesDistinctlyFromKeywords() {
        // Arrange / Act
        let runs = painted("  field @include(if: true) {", options: graphQL)

        // Assert
        #expect(runs.map(\.0) == ["@include", "true"])
        #expect(runs[0].1 == .graphQLDirective)
        #expect(runs[1].1 == .jsonKeyword)
        // Distinct colours, or neither can be picked out of a query.
        #expect(NSColor.graphQLDirective != NSColor.jsonKeyword)
        #expect(NSColor.graphQLVariable != NSColor.jsonNumber)
    }

    @Test func aCommentSwallowsEverythingAfterIt() {
        // Arrange / Act
        let line = #"  # query $var and "text" here"#
        let runs = painted(line, options: graphQL)

        // Assert -- one run, the whole comment
        #expect(runs.count == 1)
        #expect(runs[0].0 == #"# query $var and "text" here"#)
        #expect(runs[0].1 == .comment)
    }

    @Test func aStringIsNotSearchedForTokens() {
        // Arrange / Act
        let runs = painted(#"  alias: "query $notAVariable on Type""#, options: graphQL)

        // Assert -- the whole literal is one string run
        #expect(runs.count == 1)
        #expect(runs[0].0 == #""query $notAVariable on Type""#)
        #expect(runs[0].1 == .jsonString)
    }

    @Test func marksKnownAndUnknownProjectVariables() {
        // Arrange
        let options = SyntaxHighlighter.Options(knownVariableNames: ["domain"])

        // Act
        let runs = painted("https://{{domain}}/{{missing}}", options: options)

        // Assert -- green for defined, red for one that will not resolve
        #expect(runs.map(\.0) == ["{{domain}}", "{{missing}}"])
        #expect(runs[0].1 == .variableValid)
        #expect(runs[1].1 == .variableInvalid)
    }

    @Test func stillColoursJSONKeysAndValues() {
        // Arrange / Act
        let runs = painted(#"  "name": "Tatooine","#, options: .init(json: true))

        // Assert -- the key wins over the plain-string pass
        #expect(runs[0].0 == #""name""#)
        #expect(runs[0].1 == .jsonKey)
        #expect(runs[1].1 == .jsonString)
    }

    @Test func colouringIsOffByDefault() {
        #expect(SyntaxHighlighter.Options.plain.highlightsAnything == false)
        #expect(painted("query { a }", options: .plain).isEmpty)
    }
}
