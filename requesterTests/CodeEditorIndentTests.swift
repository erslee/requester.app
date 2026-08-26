import AppKit
import SwiftUI
import Testing
@testable import requester

/// Indentation is driven straight from the text view's delegate callbacks, so
/// they are exercised here against a real `NSTextView`.
@MainActor
struct CodeEditorIndentTests {
    private final class Box { var text = "" }

    private func makeEditor(_ text: String, caretAt caret: Int)
        -> (CodeEditor.Coordinator, NSTextView) {
        let box = Box()
        box.text = text
        let coordinator = CodeEditor.Coordinator(
            text: Binding(get: { box.text }, set: { box.text = $0 })
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.string = text
        textView.delegate = coordinator
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        coordinator.textView = textView
        return (coordinator, textView)
    }

    private func pressReturn(_ coordinator: CodeEditor.Coordinator, _ textView: NSTextView) -> Bool {
        coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    @Test func carriesTheCurrentIndentationToTheNextLine() {
        // Arrange -- caret at the end of an indented line
        let line = "    totalCount"
        let (coordinator, textView) = makeEditor(line, caretAt: line.utf16.count)

        // Act
        #expect(pressReturn(coordinator, textView))

        // Assert
        #expect(textView.string == "    totalCount\n    ")
        #expect(textView.selectedRange().location == textView.string.utf16.count)
    }

    @Test func goesOneLevelDeeperAfterAnOpeningBrace() {
        // Arrange
        let line = "  imageryLibrary(input: $input) {"
        let (coordinator, textView) = makeEditor(line, caretAt: line.utf16.count)

        // Act
        #expect(pressReturn(coordinator, textView))

        // Assert -- two spaces of the line's own indent, plus one level
        #expect(textView.string == "  imageryLibrary(input: $input) {\n    ")
    }

    @Test func opensABlockAroundAClosingBraceAlreadyPresent() {
        // Arrange -- caret between the braces, as after typing "{}"
        let text = "query {}"
        let (coordinator, textView) = makeEditor(text, caretAt: 7)

        // Act
        #expect(pressReturn(coordinator, textView))

        // Assert -- the closer moves to its own line and the caret sits between
        #expect(textView.string == "query {\n  \n}")
        #expect(textView.selectedRange().location == "query {\n  ".utf16.count)
    }

    @Test func addsNoIndentAfterAPlainLineAtTheMargin() {
        // Arrange
        let (coordinator, textView) = makeEditor("query", caretAt: 5)

        // Act
        #expect(pressReturn(coordinator, textView))

        // Assert
        #expect(textView.string == "query\n")
    }

    /// Without this, a closing brace typed after an auto-indented line stays
    /// one level too deep and the block never lines up.
    @Test func pullsAClosingBraceBackOneLevel() {
        // Arrange -- caret after the indentation of an otherwise empty line
        let text = "query {\n    "
        let (coordinator, textView) = makeEditor(text, caretAt: text.utf16.count)

        // Act -- type "}"
        let allowed = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: text.utf16.count, length: 0),
            replacementString: "}"
        )

        // Assert -- handled here, and the brace lands two spaces back
        #expect(allowed == false)
        #expect(textView.string == "query {\n  }")
    }

    @Test func leavesABraceClosedMidLineAlone() {
        // Arrange -- there is content before the caret, so the user placed it
        let text = "  nodes { a "
        let (coordinator, textView) = makeEditor(text, caretAt: text.utf16.count)

        // Act
        let allowed = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: text.utf16.count, length: 0),
            replacementString: "}"
        )

        // Assert -- passed through to the text view untouched
        #expect(allowed)
        #expect(textView.string == text)
    }

    @Test func doesNothingWhenAutomaticIndentingIsOff() {
        // Arrange -- the read-only viewers turn this off
        let (coordinator, textView) = makeEditor("query {", caretAt: 7)
        coordinator.indentsAutomatically = false

        // Act / Assert -- the text view handles Return itself
        #expect(pressReturn(coordinator, textView) == false)
        #expect(textView.string == "query {")
    }
}
