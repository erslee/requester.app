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

    // MARK: - Paragraphs

    /// The text view is handed one attributed line at a time, so what it draws
    /// is whatever `attributedParagraph` puts on that line -- these assert
    /// against the attributes themselves rather than against the spans.
    private let style = SyntaxHighlighter.Style(font: .monospacedSystemFont(
        ofSize: NSFont.systemFontSize, weight: .regular
    ))

    private func colour(
        _ paragraph: NSAttributedString, at index: Int
    ) -> NSColor? {
        paragraph.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    @Test func aParagraphCarriesTheColoursItsSpansDescribe() {
        // Arrange
        let line = #"  "name": "Tatooine","#

        // Act
        let paragraph = SyntaxHighlighter.attributedParagraph(
            for: line, options: .init(json: true), style: style
        )

        // Assert -- indentation stays base-coloured, the key and value do not
        #expect(paragraph.string == line)
        #expect(colour(paragraph, at: 0) == .labelColor)
        #expect(colour(paragraph, at: line.firstIndexOf(#""name""#)) == .jsonKey)
        #expect(colour(paragraph, at: line.firstIndexOf(#""Tatooine""#)) == .jsonString)
    }

    @Test func aParagraphKeepsItsTrailingNewlineUnhighlighted() {
        // Arrange / Act -- TextKit hands over the paragraph separator too
        let paragraph = SyntaxHighlighter.attributedParagraph(
            for: "  true\n", options: .init(json: true), style: style
        )

        // Assert
        #expect(paragraph.string == "  true\n")
        #expect(colour(paragraph, at: 2) == .jsonKeyword)
        #expect(colour(paragraph, at: paragraph.length - 1) == .labelColor)
    }

    @Test func plainOptionsLeaveTheWholeParagraphBaseColoured() {
        // Arrange / Act
        let paragraph = SyntaxHighlighter.attributedParagraph(
            for: #"{"a": 1}"#, options: .plain, style: style
        )

        // Assert
        var runs = 0
        paragraph.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: paragraph.length)
        ) { _, _, _ in runs += 1 }
        #expect(runs == 1)
        #expect(colour(paragraph, at: 0) == .labelColor)
    }

    @Test func searchMatchesAreShadedOnTopOfHighlighting() {
        // Arrange
        let line = #"  "name": "Tatooine","#

        // Act
        let paragraph = SyntaxHighlighter.attributedParagraph(
            for: line, options: .init(json: true), style: style, searchTerm: "tatooine"
        )

        // Assert -- the match is shaded case-insensitively, and the JSON
        // colouring underneath it survives
        let at = line.firstIndexOf("Tatooine")
        #expect(
            paragraph.attribute(.backgroundColor, at: at, effectiveRange: nil) as? NSColor
                == .findHighlightColor
        )
        #expect(colour(paragraph, at: at) == .jsonString)
        #expect(paragraph.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
    }

    @Test func theJumpedToMatchIsShadedApartFromTheRest() {
        // Arrange -- two hits on one line, the second one jumped to
        let line = "alpha beta alpha"
        let second = NSRange(location: 11, length: 5)

        // Act
        let paragraph = SyntaxHighlighter.attributedParagraph(
            for: line, options: .plain, style: style, searchTerm: "alpha", currentMatch: second
        )

        // Assert -- the other match keeps the ordinary find shading
        #expect(
            paragraph.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
                == .findHighlightColor
        )
        #expect(
            paragraph.attribute(.backgroundColor, at: 11, effectiveRange: nil) as? NSColor
                == .currentFindHighlight
        )
        #expect(colour(paragraph, at: 11) == .currentFindHighlightText)
    }

    @Test func aParagraphWithoutTheCurrentMatchIsUnaffected() {
        // Arrange / Act -- the match lives on some other line
        let paragraph = SyntaxHighlighter.attributedParagraph(
            for: "alpha", options: .plain, style: style, searchTerm: "alpha", currentMatch: nil
        )

        // Assert
        #expect(
            paragraph.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
                == .findHighlightColor
        )
    }

    @Test func aCurrentMatchRunningPastTheLineIsIgnored() {
        // Arrange / Act -- a stale jump target from a longer projection must
        // not index off the end of a line that has since been reprojected
        let paragraph = SyntaxHighlighter.attributedParagraph(
            for: "alpha", options: .plain, style: style,
            searchTerm: "alpha", currentMatch: NSRange(location: 3, length: 40)
        )

        // Assert -- it draws as an ordinary match rather than trapping
        #expect(paragraph.string == "alpha")
        #expect(
            paragraph.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
                == .findHighlightColor
        )
    }

    // MARK: - Match ranges

    @Test func findsEveryOccurrenceOfTheTerm() {
        // Arrange
        let text = "alpha beta ALPHA gamma alpha" as NSString

        // Act
        let matches = SyntaxHighlighter.matchRanges(
            of: "alpha", in: text, range: NSRange(location: 0, length: text.length)
        )

        // Assert -- case-insensitive, and each one located
        #expect(matches.count == 3)
        #expect(matches.map(\.location) == [0, 11, 23])
    }

    @Test func matchesDoNotOverlapEachOther() {
        // Arrange
        let text = "aaaa" as NSString

        // Act -- a search resumes after the match it just found
        let matches = SyntaxHighlighter.matchRanges(
            of: "aa", in: text, range: NSRange(location: 0, length: text.length)
        )

        // Assert
        #expect(matches.map(\.location) == [0, 2])
    }

    @Test func matchesStayInsideTheRangeAsked() {
        // Arrange
        let text = "alpha beta alpha" as NSString

        // Act
        let matches = SyntaxHighlighter.matchRanges(
            of: "alpha", in: text, range: NSRange(location: 5, length: text.length - 5)
        )

        // Assert -- the occurrence before the range is not reported
        #expect(matches.map(\.location) == [11])
    }

    @Test func anEmptyTermMatchesNothing() {
        // Arrange
        let text = "alpha" as NSString

        // Act / Assert -- an empty find field must not shade the whole body
        #expect(
            SyntaxHighlighter.matchRanges(
                of: "", in: text, range: NSRange(location: 0, length: text.length)
            ).isEmpty
        )
    }
}

private extension String {
    /// UTF-16 offset of `needle`, for indexing into the attributed paragraph.
    func firstIndexOf(_ needle: String) -> Int {
        (self as NSString).range(of: needle).location
    }
}
