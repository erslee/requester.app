import AppKit
import CoreGraphics
import Testing
@testable import requester

/// Whether AppKit can actually lay views out here.
///
/// Laying out a text view and tiling a scroll view needs a window server. The
/// CI runner's unit-test job has none -- it is a headless virtual machine, and
/// the attempt aborts the whole test process, taking every unrelated suite
/// down with it. So the geometry below is checked where a person can also look
/// at it, and skipped where it cannot run at all.
private enum ViewLayout {
    static var isAvailable: Bool {
        ProcessInfo.processInfo.environment["CI"] == nil
            && CGSessionCopyCurrentDictionary() != nil
    }
}

/// Where the response body's text actually lands once the line-number gutter
/// has taken its width.
///
/// The bug this guards: AppKit reserves room for a ruler as a *left content
/// inset* on the clip view rather than by narrowing it, so the leftmost scroll
/// position is minus that inset and plain `0` is the position where the gutter
/// covers the start of every line. A document nobody has scrolled sits at 0,
/// so the text arrived clipped -- the first characters of each line hidden,
/// and a one-character line gone altogether. None of that shows in the text
/// itself; it is purely where the views ended up, so it is measured here.
@Suite(.enabled(if: ViewLayout.isAvailable))
@MainActor
struct GutterGeometryTests {
    /// The editor as `CodeEditor` assembles it, showing a numbered body long
    /// enough that the gutter is wider than the 16pt AppKit starts with.
    private func makeEditor(lines: Int) -> NSScrollView {
        let (scrollView, textView) = CodeEditor.makeScrollView(isEditable: false)
        scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)

        let text = (1...lines).map { "  \"key_\($0)\": \($0)," }.joined(separator: "\n")
        textView.string = text

        let document = FoldableText.plain(text)
        let projection = document.projected(folding: [])
        CodeEditor.setWraps(
            false,
            width: CodeEditor.unwrappedWidth(longestLineLength: projection.longestLineLength),
            on: textView,
            in: scrollView
        )
        scrollView.layoutSubtreeIfNeeded()

        CodeEditor.syncGutter(
            .init(
                document: document, projection: projection, folded: [], showsFoldControls: false
            ),
            on: scrollView,
            onToggleFold: { _ in }
        )
        scrollView.layoutSubtreeIfNeeded()
        return scrollView
    }

    private func ruler(of scrollView: NSScrollView) throws -> LineNumberRuler {
        try #require(scrollView.verticalRulerView as? LineNumberRuler)
    }

    /// The gutter has to be wider than AppKit's default reservation for any of
    /// this to matter -- three digits and a margin already are.
    @Test func theGutterReservesItsOwnWidth() throws {
        // Arrange / Act
        let scrollView = makeEditor(lines: 400)

        // Assert
        let gutter = try ruler(of: scrollView)
        #expect(gutter.ruleThickness > 16)
        #expect(scrollView.contentView.contentInsets.left == gutter.ruleThickness)
    }

    /// The first characters of every line have to be on screen. Nobody
    /// scrolled, so the document belongs at the start of its lines -- which,
    /// with a left inset, is the *negative* of that inset and not zero.
    @Test func theDocumentStaysAtTheStartOfItsLines() throws {
        // Arrange / Act
        let scrollView = makeEditor(lines: 400)

        // Assert
        let clipView = scrollView.contentView
        #expect(clipView.bounds.origin.x == -clipView.contentInsets.left)
    }

    /// The same fact stated the way a reader would check it: the text view's
    /// own left edge sits to the right of the gutter, not underneath it.
    @Test func theTextBeginsAfterTheGutter() throws {
        // Arrange / Act
        let scrollView = makeEditor(lines: 400)

        // Assert
        let gutter = try ruler(of: scrollView)
        let textView = try #require(scrollView.documentView as? NSTextView)
        #expect(textView.convert(NSPoint.zero, to: scrollView).x >= gutter.ruleThickness)
    }

    /// A body with no gutter -- the raw view of a response -- gets the full
    /// width back, rather than keeping an empty strip where numbers used to be.
    @Test func droppingTheGutterGivesTheWidthBack() {
        // Arrange
        let scrollView = makeEditor(lines: 400)
        #expect(scrollView.contentView.contentInsets.left > 0)

        // Act
        CodeEditor.syncGutter(nil, on: scrollView, onToggleFold: { _ in })
        scrollView.layoutSubtreeIfNeeded()

        // Assert
        #expect(scrollView.rulersVisible == false)
        #expect(scrollView.contentView.contentInsets.left == 0)
    }
}
