import Foundation
import Testing
@testable import requester

/// The one pass that formats a body also has to say where every line starts and
/// which line closes each block -- the gutter numbers from the first and the
/// fold triangles from the second, so both are asserted against the text they
/// describe rather than in isolation.
struct FoldableTextTests {
    private let sample = #"{"name":"Luke","tags":["a","b"],"meta":{"owner":null},"ok":true}"#

    private func lines(_ document: FoldableText) -> [String] {
        document.text.components(separatedBy: "\n")
    }

    // MARK: - Indexing

    @Test func lineStartsAddressTheTextItFormatted() {
        // Arrange / Act
        let document = FoldableText.json(sample)

        // Assert -- every recorded start is the first byte of the line there
        let expected = lines(document)
        #expect(document.lineCount == expected.count)
        for line in 0..<document.lineCount {
            let start = document.lineStarts[line]
            let end = line + 1 < document.lineCount
                ? document.lineStarts[line + 1] - 1 : document.bytes.count
            #expect(String(decoding: document.bytes[start..<end], as: UTF8.self) == expected[line])
        }
    }

    @Test func utf16OffsetsDivergeFromBytesOnNonASCII() {
        // Arrange -- an accented name and an emoji, which UTF-8 and UTF-16
        // measure differently
        let document = FoldableText.json(#"{"who":"café 🙂"}"#)

        // Act
        let lastLine = document.lineCount - 1

        // Assert -- byte offsets outgrow UTF-16 offsets, and the UTF-16 ones
        // are what actually index the string TextKit sees
        #expect(document.lineStarts[lastLine] > document.utf16LineStarts[lastLine])
        let text = document.text as NSString
        for line in 0..<document.lineCount {
            #expect(
                text.substring(from: document.utf16LineStarts[line])
                    .hasPrefix(lines(document)[line])
            )
        }
    }

    // MARK: - Fold points

    @Test func pairsEachOpeningBracketWithItsCloser() {
        // Arrange / Act
        let document = FoldableText.json(sample)

        // Assert -- the object, the array and the nested object, and nothing else
        let folds = (0..<document.lineCount).compactMap { line in
            document.closingLine(for: line).map { (line, $0) }
        }
        #expect(folds.map(\.0) == [0, 2, 6])
        #expect(folds.map(\.1) == [10, 5, 8])
    }

    @Test func anEmptyBlockIsNotAFoldPoint() {
        // Arrange / Act -- the formatter keeps these inline, so there is
        // nothing for a triangle to hide
        let document = FoldableText.json(#"{"a":{},"b":[],"c":[1]}"#)

        // Assert -- only the outer object and the one-element array fold
        let foldable = (0..<document.lineCount).filter { document.closingLine(for: $0) != nil }
        #expect(foldable.count == 2)
        #expect(document.text.contains(#""a": {}"#))
        #expect(document.text.contains(#""b": []"#))
    }

    @Test func aTruncatedBodyStillFormatsAndNeverFoldsWhatDidNotClose() {
        // Arrange -- a response cut off partway, which is exactly when the
        // reader most wants it formatted
        let document = FoldableText.json(#"{"items":[{"id":1},{"id":"#)

        // Act
        let openUnclosed = (0..<document.lineCount).filter {
            document.closingLine(for: $0) != nil
        }

        // Assert -- the closed inner object folds; the two brackets still open
        // at the end do not
        #expect(document.text.hasPrefix("{\n  \"items\": [\n"))
        #expect(openUnclosed.allSatisfy { document.closingLine(for: $0)! < document.lineCount })
    }

    // MARK: - Projection

    @Test func foldingRejoinsAnOpenerToItsCloser() {
        // Arrange
        let document = FoldableText.json(sample)

        // Act -- collapse the "tags" array on line 2
        let projection = document.projected(folding: [2])

        // Assert -- the block reads as the thing it stands for, and the lines
        // it swallowed are gone
        #expect(projection.text.contains(#""tags": [ ⋯ ],"#))
        #expect(!projection.text.contains(#""a","#))
        #expect(projection.lineCount == document.lineCount - 3)
    }

    @Test func aProjectionRemembersWhichSourceLineEachRowCameFrom() {
        // Arrange
        let document = FoldableText.json(sample)

        // Act
        let projection = document.projected(folding: [2])

        // Assert -- the gutter numbers from this, so the row after the fold
        // must report the source line it really is
        #expect(projection.sourceLines == [0, 1, 2, 6, 7, 8, 9, 10])
        #expect(projection.lineCount == projection.sourceLines.count)
    }

    @Test func projectedLineStartsIndexTheProjectedText() {
        // Arrange
        let document = FoldableText.json(sample)

        // Act
        let projection = document.projected(folding: [2, 5])

        // Assert -- what the gutter binary-searches has to address the string
        // the text view is holding, marker and all
        let text = projection.text as NSString
        let expected = projection.text.components(separatedBy: "\n")
        for line in 0..<projection.lineCount {
            #expect(text.substring(from: projection.lineStarts[line]).hasPrefix(expected[line]))
        }
    }

    @Test func foldingNothingReproducesTheFormattedText() {
        // Arrange / Act
        let document = FoldableText.json(sample)

        // Assert -- an unfolded projection is the body as the formatter left it
        #expect(document.projected(folding: []).text == document.text)
    }

    @Test func aLineThatOpensNothingIsIgnoredWhenFolded() {
        // Arrange -- line 1 is `"name": "Luke",`, which has no block
        let document = FoldableText.json(sample)

        // Act / Assert -- asking to fold it changes nothing
        #expect(document.projected(folding: [1]).text == document.text)
    }

    @Test func offsetsSurviveAFoldMarkerOnNonASCIIText() {
        // Arrange -- the marker itself is non-ASCII, so a projection that
        // counted bytes would put every following line out of step
        let document = FoldableText.json(#"{"who":"café","tags":["🙂","b"]}"#)
        let tagsLine = (0..<document.lineCount).first {
            document.closingLine(for: $0) != nil && $0 > 0
        }

        // Act
        let projection = document.projected(folding: [tagsLine!])

        // Assert
        let text = projection.text as NSString
        let expected = projection.text.components(separatedBy: "\n")
        for line in 0..<projection.lineCount {
            #expect(text.substring(from: projection.lineStarts[line]).hasPrefix(expected[line]))
        }
        #expect(projection.text.contains("⋯"))
    }

    @Test func displayedLineIsFoundForAnyOffsetInIt() {
        // Arrange
        let projection = FoldableText.json(sample).projected(folding: [])

        // Act / Assert -- every offset maps back to the line containing it
        let text = projection.text as NSString
        for offset in 0..<text.length {
            let line = projection.displayedLine(containing: offset)
            #expect(projection.lineStarts[line] <= offset)
            if line + 1 < projection.lineCount {
                #expect(offset < projection.lineStarts[line + 1])
            }
        }
    }

    // MARK: - Applying a fold as an edit

    /// Every case has to satisfy the same property: applying the reported edit
    /// to the previous text must produce the new text exactly. If it does not,
    /// the text view and the line map drift apart.
    private func applying(
        _ difference: (range: NSRange, replacement: String)?, to previous: String
    ) -> String {
        guard let difference else { return previous }
        return (previous as NSString).replacingCharacters(
            in: difference.range, with: difference.replacement
        )
    }

    @Test func collapsingReportsAnEditThatReproducesTheFoldedText() {
        // Arrange
        let document = FoldableText.json(sample)
        let open = document.projected(folding: [])
        let closed = document.projected(folding: [2])

        // Act
        let edit = closed.difference(from: open)

        // Assert -- and the edit is the block, not the whole document
        #expect(applying(edit, to: open.text) == closed.text)
        #expect(edit!.range.length < (open.text as NSString).length)
    }

    @Test func expandingReportsTheReverseEdit() {
        // Arrange
        let document = FoldableText.json(sample)
        let closed = document.projected(folding: [2])
        let open = document.projected(folding: [])

        // Act / Assert
        #expect(applying(open.difference(from: closed), to: closed.text) == open.text)
    }

    @Test func theEditCoversTheOpenerWhoseTextGainedTheMarker() {
        // Arrange -- the opening line keeps its source line but changes text,
        // so an edit matched on line numbers alone would start too late
        let document = FoldableText.json(sample)
        let open = document.projected(folding: [])
        let closed = document.projected(folding: [2])

        // Act
        let edit = closed.difference(from: open)!

        // Assert -- the replaced span begins at the opening line, not after it
        #expect(edit.range.location == open.lineStarts[2])
        #expect(edit.replacement.contains("⋯"))
    }

    @Test func anUnchangedProjectionReportsNoEdit() {
        // Arrange / Act / Assert
        let document = FoldableText.json(sample)
        let projection = document.projected(folding: [2])
        #expect(projection.difference(from: document.projected(folding: [2])) == nil)
    }

    @Test func foldingTheFirstAndLastBlocksStillReproducesTheText() {
        // Arrange -- the outermost block runs to the final line, where the
        // ranges have no newline to lean on
        let document = FoldableText.json(sample)
        let open = document.projected(folding: [])

        for folded in [Set([0]), Set([6]), Set([2, 6]), Set([0, 2, 6])] {
            // Act
            let closed = document.projected(folding: folded)

            // Assert
            #expect(applying(closed.difference(from: open), to: open.text) == closed.text)
            #expect(applying(open.difference(from: closed), to: closed.text) == open.text)
        }
    }

    @Test func aSecondFoldEditsOnlyTheBlockItCollapsed() {
        // Arrange -- collapsing one block while another is already collapsed
        let document = FoldableText.json(sample)
        let one = document.projected(folding: [2])
        let two = document.projected(folding: [2, 6])

        // Act
        let edit = two.difference(from: one)!

        // Assert -- the text is reproduced, and the first fold is untouched
        #expect(applying(edit, to: one.text) == two.text)
        #expect(edit.range.location >= one.lineStarts[3])
    }

    @Test func editsHoldOnNonASCIIText() {
        // Arrange -- UTF-16 ranges, not byte ranges, are what a text view takes
        let document = FoldableText.json(#"{"who":"café 🙂","tags":["a","b"]}"#)
        let open = document.projected(folding: [])
        let block = (1..<document.lineCount).first { document.closingLine(for: $0) != nil }!

        // Act
        let closed = document.projected(folding: [block])

        // Assert
        #expect(applying(closed.difference(from: open), to: open.text) == closed.text)
        #expect(applying(open.difference(from: closed), to: closed.text) == open.text)
    }

    // MARK: - Plain text

    @Test func plainTextIsIndexedButNeverFoldable() {
        // Arrange / Act -- a non-JSON body still gets line numbers
        let document = FoldableText.plain("one\ntwo\nthree")

        // Assert
        #expect(document.text == "one\ntwo\nthree")
        #expect(document.lineCount == 3)
        #expect((0..<document.lineCount).allSatisfy { document.closingLine(for: $0) == nil })
    }
}
