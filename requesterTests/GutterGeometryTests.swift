import AppKit
import Testing
@testable import requester

/// Where the response body's text actually lands once the line-number gutter
/// has taken its width.
///
/// The bug this guards: as an `NSRulerView`, the gutter's width was reserved as
/// a *left content inset* on a clip view that stayed full width, so the numbers
/// were painted over the text and the text only cleared them at the one scroll
/// position where the document sat at minus that inset. Scrolling sideways --
/// which is the response body's default, since its lines do not wrap -- put the
/// first characters of every line underneath the numbers, and so did any window
/// resize that re-clamped the scroll offset.
///
/// The gutter is a neighbour of the scroll view now, so the two cannot overlap
/// at any offset. None of that shows in the text itself; it is purely where the
/// views ended up, so it is measured here.
@MainActor
struct GutterGeometryTests {
    /// The editor as `CodeEditor` assembles it, showing a numbered body long
    /// enough that the gutter is wider than the 16pt AppKit used to start with,
    /// and wide enough that it has somewhere to scroll sideways to.
    private func makeEditor(lines: Int, width: CGFloat = 600) -> GutteredEditor {
        let editor = GutteredEditor(isEditable: false)
        editor.frame = NSRect(x: 0, y: 0, width: width, height: 400)

        let text = (1...lines)
            .map { "  \"key_\($0)\": \"a value long enough to run off the side\"," }
            .joined(separator: "\n")
        editor.textView.string = text

        let document = FoldableText.plain(text)
        let projection = document.projected(folding: [])
        editor.setWraps(
            false, unwrappedWidth: CodeEditor.unwrappedWidth(
                longestLineLength: projection.longestLineLength
            )
        )
        editor.setGutter(source(for: text)) { _ in }
        editor.layoutSubtreeIfNeeded()
        return editor
    }

    /// The same source the panel would hand back, rebuilt from the text on
    /// screen rather than kept from before -- which is what switching the
    /// format does.
    private func source(for text: String) -> LineNumberGutter.Source {
        let document = FoldableText.plain(text)
        return .init(
            document: document,
            projection: document.projected(folding: []),
            folded: [],
            showsFoldControls: false
        )
    }

    private func gutter(of editor: GutteredEditor) throws -> LineNumberGutter {
        try #require(editor.subviews.compactMap { $0 as? LineNumberGutter }.first)
    }

    /// Where the reader sees the leftmost column of text: the document offset
    /// currently at the viewport's left edge, in the editor's own coordinates.
    /// Anything below the gutter's right edge is hidden underneath it.
    ///
    /// With no content inset this reduces to the scroll view's own left edge,
    /// so it says little about the layout as it now stands. It is written the
    /// long way on purpose: against the ruler it evaluated to zero at any
    /// scroll position but the first, and that is the regression it guards.
    private func leftEdgeOfText(in editor: GutteredEditor) -> CGFloat {
        let scrolledTo = editor.scrollView.contentView.bounds.origin
        return editor.textView.convert(NSPoint(x: scrolledTo.x, y: 0), to: editor).x
    }

    /// The gutter has to be wider than AppKit's default reservation for any of
    /// this to matter -- three digits and a margin already are -- and it takes
    /// that width out of the scroll view rather than off the top of it.
    @Test func theGutterTakesItsOwnColumn() throws {
        // Arrange / Act
        let editor = makeEditor(lines: 400)

        // Assert
        let gutter = try gutter(of: editor)
        #expect(gutter.thickness > 16)
        #expect(editor.scrollView.frame.minX == gutter.frame.maxX)
        #expect(editor.scrollView.frame.width == editor.bounds.width - gutter.thickness)
        // The inset was the whole mechanism of the old overlap. There isn't one.
        #expect(editor.scrollView.contentView.contentInsets.left == 0)
    }

    /// The first characters of every line have to be on screen. Nobody
    /// scrolled, so the document is at the start of its lines -- plain zero,
    /// with no inset to subtract.
    @Test func theDocumentStartsAtTheStartOfItsLines() throws {
        // Arrange / Act
        let editor = makeEditor(lines: 400)

        // Assert
        #expect(editor.scrollView.contentView.bounds.origin.x == 0)
        #expect(try leftEdgeOfText(in: editor) >= gutter(of: editor).frame.maxX)
    }

    /// Scrolled sideways through an unwrapped body -- the response body's
    /// default -- the column at the left edge of the viewport is still one the
    /// reader can see. Under a ruler it was the column *behind* the numbers.
    @Test func scrollingSidewaysKeepsTheTextOutFromUnderTheGutter() throws {
        // Arrange
        let editor = makeEditor(lines: 400)
        let clipView = editor.scrollView.contentView

        // Act
        clipView.scroll(to: NSPoint(x: 200, y: 0))
        editor.scrollView.reflectScrolledClipView(clipView)
        editor.layoutSubtreeIfNeeded()

        // Assert
        #expect(clipView.bounds.origin.x == 200)
        #expect(try leftEdgeOfText(in: editor) >= gutter(of: editor).frame.maxX)
    }

    /// The reported bug: resizing the window while the body is scrolled
    /// sideways re-clamps the scroll offset, and every offset but one used to
    /// put text under the numbers.
    @Test func resizingWhileScrolledKeepsTheTextOutFromUnderTheGutter() throws {
        // Arrange
        let editor = makeEditor(lines: 400)
        let clipView = editor.scrollView.contentView
        clipView.scroll(to: NSPoint(x: 200, y: 0))
        editor.scrollView.reflectScrolledClipView(clipView)
        editor.layoutSubtreeIfNeeded()

        // Act / Assert -- narrower, wider, and wider than the document itself
        for width in [420.0, 780.0, 3000.0] as [CGFloat] {
            editor.setFrameSize(NSSize(width: width, height: 400))
            editor.layoutSubtreeIfNeeded()

            let gutter = try gutter(of: editor)
            #expect(leftEdgeOfText(in: editor) >= gutter.frame.maxX)
            #expect(editor.scrollView.frame.minX == gutter.frame.maxX)
        }
    }

    /// A wrapped line has to break at the edge the reader can see. The ruler
    /// was not subtracted from `NSScrollView.contentSize`, so the text view was
    /// laid out a gutter's width wider than the viewport and the tail of every
    /// line sat off the right-hand side.
    @Test func wrappingBreaksAtTheVisibleEdge() throws {
        // Arrange
        let editor = makeEditor(lines: 400)

        // Act
        editor.setWraps(true, unwrappedWidth: 0)
        editor.layoutSubtreeIfNeeded()

        // Assert -- the text lays out to the viewport it is actually in, and
        // that viewport is what is left of the editor once the gutter has its
        // column. Stated against `contentSize` rather than against the editor's
        // own width, which would disagree by a legacy vertical scroller.
        let gutter = try gutter(of: editor)
        #expect(editor.textView.frame.width == editor.scrollView.contentSize.width)
        #expect(editor.textView.frame.width <= editor.bounds.width - gutter.thickness)
    }

    /// A body with no gutter -- the raw view of a response -- gets the full
    /// width back, rather than keeping an empty strip where numbers used to be.
    @Test func droppingTheGutterGivesTheWidthBack() throws {
        // Arrange
        let editor = makeEditor(lines: 400)
        #expect(try gutter(of: editor).thickness > 0)

        // Act
        editor.setGutter(nil) { _ in }
        editor.layoutSubtreeIfNeeded()

        // Assert
        #expect(try gutter(of: editor).thickness == 0)
        #expect(editor.scrollView.frame == editor.bounds)
    }

    /// Raw and back again, the round trip that used to leave the document at
    /// the offset it had while there was no gutter -- which was the offset
    /// where the gutter covered the start of every line.
    @Test func restoringTheGutterPutsTheTextBackBesideIt() throws {
        // Arrange -- shown, dropped for the raw view
        let editor = makeEditor(lines: 400)
        let thickness = try gutter(of: editor).thickness
        editor.setGutter(nil) { _ in }
        editor.layoutSubtreeIfNeeded()

        // Act -- and back to pretty, the same document and the same gutter
        editor.setGutter(source(for: editor.textView.string)) { _ in }
        editor.layoutSubtreeIfNeeded()

        // Assert
        let gutter = try gutter(of: editor)
        #expect(gutter.thickness == thickness)
        #expect(editor.scrollView.frame.minX == thickness)
        #expect(leftEdgeOfText(in: editor) >= gutter.frame.maxX)
    }

    /// The gutter is as tall as the text beside it, so it stops rather than
    /// running down past the last row into the horizontal scroller's strip.
    ///
    /// Forced to legacy scrollers, which take real height out of the clip view.
    /// Overlay scrollers -- the default, and what CI has -- float over the text
    /// and leave nothing to collide with, so the property is invisible there.
    @Test func theGutterStopsWhereTheTextDoes() throws {
        // Arrange -- unwrapped and wider than the viewport, so there is one
        let editor = makeEditor(lines: 400)

        // Act
        editor.scrollView.scrollerStyle = .legacy
        editor.layoutSubtreeIfNeeded()

        // Assert
        let gutter = try gutter(of: editor)
        let scroller = try #require(editor.scrollView.horizontalScroller)
        #expect(editor.scrollView.hasHorizontalScroller)
        #expect(gutter.frame.height < editor.bounds.height)
        #expect(!gutter.frame.intersects(editor.convert(scroller.frame, from: editor.scrollView)))
    }

    /// Turning wrapping off is what puts the horizontal scroller there, and it
    /// arrives without any frame change to prompt a layout -- so the gutter was
    /// left measured against a viewport a scroller's height taller than the one
    /// the text ended up in.
    @Test func togglingWrapResizesTheGutterWithTheViewport() throws {
        // Arrange -- wrapped, so there is no horizontal scroller yet
        let editor = makeEditor(lines: 400)
        editor.scrollView.scrollerStyle = .legacy
        editor.setWraps(true, unwrappedWidth: 0)
        editor.layoutSubtreeIfNeeded()
        let wrappedHeight = try gutter(of: editor).frame.height

        // Act -- back to unwrapped, which brings the scroller with it
        editor.setWraps(
            false,
            unwrappedWidth: CodeEditor.unwrappedWidth(
                longestLineLength: FoldableText.plain(editor.textView.string)
                    .projected(folding: []).longestLineLength
            )
        )
        editor.layoutSubtreeIfNeeded()

        // Assert
        let gutter = try gutter(of: editor)
        #expect(gutter.frame.height < wrappedHeight)
        let scroller = try #require(editor.scrollView.horizontalScroller)
        #expect(!gutter.frame.intersects(editor.convert(scroller.frame, from: editor.scrollView)))
    }
}
