import Foundation
import Testing
@testable import requester

/// The repairer runs on every paste into a JSON editor, so the tests come in
/// two halves: what it fixes, and -- just as important -- what it refuses to
/// touch. A wrong repair silently corrupts a request body.
struct RelaxedJSONTests {
    /// The shape this exists for: a console log copied straight out of a
    /// browser or a Node REPL.
    @Test func repairsAConsoleLoggedObject() {
        // Arrange
        let pasted = """
            {
              projectId: '708000c9-61de-40',
              designId: 'desjsrkkow58sk3txwy',
              layout_project_id: 'prol2muivo0lq2cvg3h',
              units: [ 'A1.2a' ],
              catalogId: 'cat5a0a0803-afc5'
            }
            """

        // Act
        let repaired = RelaxedJSON.repaired(pasted)

        // Assert
        #expect(repaired == """
            {
              "projectId": "708000c9-61de-40",
              "designId": "desjsrkkow58sk3txwy",
              "layout_project_id": "prol2muivo0lq2cvg3h",
              "units": [
                "A1.2a"
              ],
              "catalogId": "cat5a0a0803-afc5"
            }
            """)
    }

    @Test func dropsTrailingCommas() {
        // Act
        let repaired = RelaxedJSON.repaired("""
            {"a": [1, 2,], "b": 3,}
            """)

        // Assert
        #expect(repaired == """
            {
              "a": [
                1,
                2
              ],
              "b": 3
            }
            """)
    }

    @Test func stripsComments() {
        // Act
        let repaired = RelaxedJSON.repaired("""
            {
              // the id to update
              "id": 4, /* inline */
              "n": 5
            }
            """)

        // Assert
        #expect(repaired == """
            {
              "id": 4,
              "n": 5
            }
            """)
    }

    @Test func keepsNumbersBooleansAndNull() {
        // Act
        let repaired = RelaxedJSON.repaired("{ n: -1.5e3, ok: true, off: false, missing: null }")

        // Assert
        #expect(repaired == """
            {
              "n": -1.5e3,
              "ok": true,
              "off": false,
              "missing": null
            }
            """)
    }

    @Test func quotesKeysThatNeedIt() {
        // Act
        let repaired = RelaxedJSON.repaired("{ $ref: 1, x-trace: 2, a.b: 3, _p: 4, 5: 6 }")

        // Assert
        #expect(repaired == """
            {
              "$ref": 1,
              "x-trace": 2,
              "a.b": 3,
              "_p": 4,
              "5": 6
            }
            """)
    }

    // MARK: - What must survive untouched

    /// The rule that makes quoting bare keys safe at all: `id:` inside a string
    /// is content.
    @Test func leavesPunctuationInsideStringsAlone() {
        // Act
        let repaired = RelaxedJSON.repaired(#"{ note: 'id: 4, // not a comment', ok: true }"#)

        // Assert
        #expect(repaired == """
            {
              "note": "id: 4, // not a comment",
              "ok": true
            }
            """)
    }

    @Test func rewritesQuotesInsideAConvertedString() {
        // Act
        let repaired = RelaxedJSON.repaired(#"{ a: 'it\'s "quoted"', b: "left\nalone" }"#)

        // Assert -- \' loses its backslash, a bare " gains one, \n is untouched
        #expect(repaired == """
            {
              "a": "it's \\"quoted\\"",
              "b": "left\\nalone"
            }
            """)
    }

    /// Nil means "insert what was pasted, verbatim".
    @Test func declinesTextThatIsAlreadyValidJSON() {
        // Assert -- a body deliberately pasted minified stays minified
        #expect(RelaxedJSON.repaired(#"{"a":1,"b":[2]}"# ) == nil)
    }

    @Test func declinesTextThatIsNotObjectShaped() {
        // Assert
        #expect(RelaxedJSON.repaired("hello world") == nil)
        #expect(RelaxedJSON.repaired("name=value&other=2") == nil)
        #expect(RelaxedJSON.repaired("") == nil)
    }

    @Test func declinesWhatItCannotRepair() {
        // Assert -- a JS expression, a call, and a string that never closes
        #expect(RelaxedJSON.repaired("{ a: undefined }") == nil)
        #expect(RelaxedJSON.repaired("{ at: new Date() }") == nil)
        #expect(RelaxedJSON.repaired("{ a: 'unterminated") == nil)
    }

    /// `{{variables}}` are resolved at send time, so a templated body must come
    /// through a paste unharmed.
    @Test func keepsVariableTemplatesInStrings() {
        // Act
        let repaired = RelaxedJSON.repaired("{ token: '{{authToken}}' }")

        // Assert
        #expect(repaired == """
            {
              "token": "{{authToken}}"
            }
            """)
    }
}
