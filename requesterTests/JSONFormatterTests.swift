import Foundation
import Testing
@testable import requester

/// A minified response arrives as one enormous line. Formatting it has to work
/// on a body that has been cut off for display, which is precisely where
/// `JSONSerialization` cannot help.
struct JSONFormatterTests {
    @Test func formatsNestedJSON() {
        // Arrange / Act
        let formatted = JSONFormatter.prettyPrinted(#"{"a":1,"b":[{"c":"d"}]}"#)

        // Assert
        #expect(formatted == """
            {
              "a": 1,
              "b": [
                {
                  "c": "d"
                }
              ]
            }
            """)
    }

    @Test func keepsEmptyContainersOnOneLine() {
        // Assert -- an empty object or array should not become three lines
        #expect(JSONFormatter.prettyPrinted(#"{"a":{},"b":[]}"#) == """
            {
              "a": {},
              "b": []
            }
            """)
    }

    /// Punctuation inside a string is content, not structure.
    @Test func leavesStringContentAlone() {
        // Arrange
        let json = #"{"s":"a, b: {c} [d]","esc":"say \"hi\"","slash":"a\\b"}"#

        // Act
        let formatted = JSONFormatter.prettyPrinted(json)

        // Assert -- values survive verbatim, on their own lines
        #expect(formatted.contains(#""s": "a, b: {c} [d]""#))
        #expect(formatted.contains(#""esc": "say \"hi\"""#))
        #expect(formatted.contains(#""slash": "a\\b""#))
        #expect(formatted.split(separator: "\n").count == 5)
    }

    /// The display body is truncated at 256,000 characters, so it is not valid
    /// JSON -- the case that matters most and the one a parser cannot handle.
    @Test func formatsABodyThatIsCutOffPartway() throws {
        // Arrange
        let truncated = #"{"nodes":[{"a":1},{"b":"cut off here"#
        #expect((try? JSONSerialization.jsonObject(with: Data(truncated.utf8))) == nil)

        // Act
        let formatted = JSONFormatter.prettyPrinted(truncated)

        // Assert -- everything up to the cut is laid out, and nothing is lost
        #expect(formatted == """
            {
              "nodes": [
                {
                  "a": 1
                },
                {
                  "b": "cut off here
            """)
    }

    @Test func replacesTheInputsOwnWhitespace() {
        // Arrange -- already-formatted input should be re-laid-out, not doubled
        let alreadyPretty = "{\n\n    \"a\" :   1\n}"

        // Act / Assert
        #expect(JSONFormatter.prettyPrinted(alreadyPretty) == """
            {
              "a": 1
            }
            """)
    }

    @Test func formatsOnlyWhatLooksLikeJSON() {
        // Assert -- HTML and plain text are left exactly as they are
        let html = "<!DOCTYPE html><html><body>{not json}</body></html>"
        #expect(JSONFormatter.prettyPrintedIfJSON(html) == html)
        #expect(JSONFormatter.prettyPrintedIfJSON("plain text") == "plain text")
        #expect(JSONFormatter.prettyPrintedIfJSON("") == "")

        #expect(JSONFormatter.looksLikeJSON(#"{"a":1}"#))
        #expect(JSONFormatter.looksLikeJSON("  \n [1,2] "))
        #expect(!JSONFormatter.looksLikeJSON("<html>"))
    }

    /// The whole point: one unreadable line becomes many short ones. Long lines
    /// are also the worst case for text layout, so this makes the panel faster
    /// as well as legible.
    @Test func turnsOneLongLineIntoManyShortOnes() {
        // Arrange
        let node = #"{"id":"abc","name":"windward","__typename":"Organization"}"#
        let minified = "{\"nodes\":[" + Array(repeating: node, count: 200).joined(separator: ",") + "]}"

        // Act
        let formatted = JSONFormatter.prettyPrinted(minified)

        // Assert
        let lines = formatted.split(separator: "\n")
        #expect(minified.split(separator: "\n").count == 1)
        #expect(lines.count > 800)
        #expect(lines.map(\.count).max() ?? 0 < 60)
    }
}
