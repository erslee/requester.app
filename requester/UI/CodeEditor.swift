import AppKit
import SwiftUI

/// A monospaced text editor with live syntax highlighting.
///
/// Wraps `NSTextView` rather than using `TextEditor`: highlighting means
/// rewriting attributes on every keystroke, and only the text view lets that
/// happen against its own text storage without disturbing the insertion point.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var options: SyntaxHighlighter.Options = .plain
    var isEditable: Bool = true
    var searchTerm: String = ""

    /// Carries indentation onto the next line, and outdents a closing bracket.
    var indentsAutomatically: Bool = true

    /// Line numbers and fold triangles down the left. Nil -- the default, and
    /// what every editable editor uses -- shows no gutter at all.
    var gutter: LineNumberRuler.Source?

    /// Called with the source line whose fold triangle was clicked.
    var onToggleFold: ((Int) -> Void)?

    /// Off means long lines scroll sideways instead of wrapping, which is what
    /// keeps one line to one gutter row.
    var wrapsLines: Bool = true

    /// The search match the reader last jumped to. It is scrolled into view and
    /// shaded apart from the others.
    var highlightedMatch: NSRange?

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isRichText = false
        textView.allowsUndo = isEditable
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = Self.font
        textView.textContainerInset = CGSize(width: 6, height: 8)
        textView.drawsBackground = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        Self.setWraps(wrapsLines, width: unwrappedWidth, on: textView, in: scrollView)

        if gutter != nil {
            let ruler = LineNumberRuler(scrollView: scrollView)
            ruler.onToggleFold = { [weak coordinator = context.coordinator] line in
                coordinator?.onToggleFold?(line)
            }
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        }
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            scrollView.setContentHuggingPriority(.defaultLow, for: axis)
            scrollView.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }

        context.coordinator.textView = textView

        // Installed before any text is set, so the very first layout pass is
        // already highlighted: TextKit asks the delegate for each paragraph as
        // it scrolls into view.
        textView.textContentStorage?.delegate = context.coordinator
        context.coordinator.apply(
            options: options, searchTerm: searchTerm, highlightedMatch: highlightedMatch
        )
        context.coordinator.onToggleFold = onToggleFold
        textView.string = text
        (scrollView.verticalRulerView as? LineNumberRuler)?.source = gutter
        return scrollView
    }

    /// Fills whatever it is offered, and never reports an intrinsic size: the
    /// scroll view's fitting size derives from its text, so a single long JSON
    /// line would otherwise make the editor demand an enormous width and squeeze
    /// the sidebar and inspector out of the window.
    ///
    /// A proposal is not always a usable number. SwiftUI probes with `nil`
    /// (unspecified) and with infinity (asking for the ideal size), and neither
    /// can be handed back as a concrete frame -- an infinite or NaN frame sends
    /// AppKit into a recursive layout pass that overflows the stack and kills
    /// the process. Only finite, positive values are passed through.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSScrollView, context: Context
    ) -> CGSize? {
        CGSize(
            width: Self.usableLength(proposal.width, whenUnusable: 360),
            height: Self.usableLength(proposal.height, whenUnusable: 220)
        )
    }

    private static func usableLength(_ value: CGFloat?, whenUnusable fallback: CGFloat) -> CGFloat {
        guard let value, value.isFinite, value > 0 else { return fallback }
        return value
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        context.coordinator.indentsAutomatically = indentsAutomatically
        context.coordinator.onToggleFold = onToggleFold
        textView.isEditable = isEditable
        textView.allowsUndo = isEditable
        Self.setWraps(wrapsLines, width: unwrappedWidth, on: textView, in: scrollView)

        // Only push text in when it changed outside the editor (a request was
        // loaded, a curl command imported, a block was collapsed) -- otherwise
        // typing would fight with the binding and reset the cursor.
        if textView.string != text {
            let selection = textView.selectedRange()
            // Collapsing a block is an edit to one region, not a new document.
            // Applying it as one keeps the reader where they were.
            if !context.coordinator.applyFold(to: gutter, in: textView) {
                textView.string = text
                textView.setSelectedRange(
                    NSRange(location: min(selection.location, text.utf16.count), length: 0)
                )
            }
        }
        context.coordinator.gutter = gutter
        context.coordinator.apply(
            options: options, searchTerm: searchTerm, highlightedMatch: highlightedMatch
        )

        // The gutter draws from the projection, so it is refreshed whenever the
        // text it numbers might have moved. Redrawing costs a screenful.
        (scrollView.verticalRulerView as? LineNumberRuler)?.source = gutter
    }

    /// Beyond this, a line is wrapped whatever the caller asked for. Only the
    /// minified case reaches it -- a whole body on one line, which would mean a
    /// text view tens of millions of points wide. A bounded container stays
    /// lazy at any width short of that, so the limit is deliberately far above
    /// anything a formatted response produces.
    static let widestUnwrappedLine: CGFloat = 1_000_000

    /// Turns wrapping on or off without giving up viewport layout.
    ///
    /// The container's width must stay **bounded**. Handing it
    /// `greatestFiniteMagnitude` -- the conventional recipe for a non-wrapping
    /// text view -- makes TextKit lay out every paragraph in the document to
    /// discover how wide the widest one is: measured at 3.3 seconds for a 2 MB
    /// response, against 4 ms. So the container keeps tracking the text view,
    /// and the *text view* is widened instead, to a width the caller already
    /// knows from its line index.
    ///
    /// Nothing here assigns `container.size` or asks the text view to size
    /// itself to its text. Both would make TextKit measure the whole document,
    /// and the first also fights the tracking that derives the container width
    /// from the view's -- they disagree by the text container inset, so every
    /// update would overwrite what the last layout pass had just worked out.
    private static func setWraps(
        _ wraps: Bool, width contentWidth: CGFloat,
        on textView: NSTextView, in scrollView: NSScrollView
    ) {
        guard let container = textView.textContainer else { return }
        let wrapped = wraps || contentWidth > widestUnwrappedLine
        let width = wrapped
            ? scrollView.contentSize.width
            : max(contentWidth, scrollView.contentSize.width)

        guard textView.isHorizontallyResizable == wrapped
            || abs(textView.frame.width - width) > 0.5
        else { return }

        container.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        // A wrapped view follows the scroll view's width; a widened one must
        // not be pulled back to it on the next resize.
        textView.autoresizingMask = wrapped ? [.width] : []
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        scrollView.hasHorizontalScroller = !wrapped
    }

    /// Width the text needs when it is not wrapped. The editors are monospaced,
    /// so the longest line's character count is the document's width -- no
    /// layout required to find it.
    static func unwrappedWidth(longestLineLength: Int) -> CGFloat {
        CGFloat(longestLineLength) * font.maximumAdvancement.width + 24
    }

    /// Whether a document with this longest line can be shown unwrapped at all,
    /// so a Wrap control can be disabled rather than appear to do nothing.
    static func canUnwrap(longestLineLength: Int) -> Bool {
        unwrappedWidth(longestLineLength: longestLineLength) <= widestUnwrappedLine
    }

    private var unwrappedWidth: CGFloat {
        guard let gutter else { return 0 }
        return Self.unwrappedWidth(longestLineLength: gutter.projection.longestLineLength)
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(text: $text)
        coordinator.indentsAutomatically = indentsAutomatically
        return coordinator
    }

    static var font: NSFont {
        .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        /// Two spaces, matching the JSON formatter and GraphQL convention.
        static let indentUnit = "  "

        var text: Binding<String>
        var indentsAutomatically = true
        var onToggleFold: ((Int) -> Void)?

        /// The projection currently on screen, so a reprojection can be applied
        /// as an edit to the region it changed.
        var gutter: LineNumberRuler.Source?

        weak var textView: NSTextView?

        /// Fonts resolved once, since every paragraph scrolling into view is
        /// styled through them.
        private let style = SyntaxHighlighter.Style(font: CodeEditor.font)

        /// What paragraphs are currently being styled with. `updateNSView` runs
        /// on every surrounding state change -- a send starting, a tab
        /// switching -- so re-styling is triggered only when one of these two
        /// actually differs. Both are cheap to compare; the document is not
        /// consulted at all.
        private var options: SyntaxHighlighter.Options = .plain
        private var searchTerm = ""
        private var highlightedMatch: NSRange?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.string
        }

        // MARK: - Indentation

        /// Return keeps the current line's indentation, and goes one level
        /// deeper after an opening bracket, so a nested query stays readable
        /// while it is being typed.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard indentsAutomatically,
                  selector == #selector(NSResponder.insertNewline(_:))
            else { return false }

            let text = textView.string as NSString
            let selection = textView.selectedRange()
            let lineStart = text.lineRange(
                for: NSRange(location: selection.location, length: 0)
            ).location
            let beforeCaret = text.substring(
                with: NSRange(
                    location: lineStart,
                    length: max(selection.location - lineStart, 0)
                )
            )

            let indent = String(beforeCaret.prefix { $0 == " " || $0 == "\t" })
            let lastMeaningful = beforeCaret.reversed().first { !$0.isWhitespace }
            let closerForOpener: [Character: Character] = ["{": "}", "(": ")", "[": "]"]
            let opensBlock = lastMeaningful.map { closerForOpener.keys.contains($0) } ?? false

            var insertion = "\n" + indent + (opensBlock ? Self.indentUnit : "")
            let caretOffset = insertion.utf16.count

            // With the matching closer already sitting after the caret, put it
            // on its own line so the block comes out correctly spaced.
            if opensBlock, let opener = lastMeaningful {
                let trailing = text.substring(from: NSMaxRange(selection))
                if trailing.prefix(64).first(where: { !$0.isWhitespace })
                    == closerForOpener[opener] {
                    insertion += "\n" + indent
                }
            }

            textView.insertText(insertion, replacementRange: selection)
            textView.setSelectedRange(
                NSRange(location: selection.location + caretOffset, length: 0)
            )
            return true
        }

        /// A closing bracket typed at the start of a line pulls that line back
        /// one level, so it lines up with the line that opened the block.
        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard indentsAutomatically,
                  let replacement = replacementString,
                  let character = replacement.first,
                  replacement.count == 1,
                  "})]".contains(character)
            else { return true }

            let text = textView.string as NSString
            let lineStart = text.lineRange(
                for: NSRange(location: affectedRange.location, length: 0)
            ).location
            let beforeCaret = text.substring(
                with: NSRange(
                    location: lineStart,
                    length: max(affectedRange.location - lineStart, 0)
                )
            )

            // Only when nothing but indentation precedes it: a bracket closed
            // mid-line is already where the user wants it.
            guard !beforeCaret.isEmpty,
                  beforeCaret.allSatisfy({ $0 == " " || $0 == "\t" })
            else { return true }

            let outdented = Self.removingOneIndentLevel(from: beforeCaret)
            let lineIndentRange = NSRange(location: lineStart, length: beforeCaret.utf16.count)
            textView.insertText(outdented + replacement, replacementRange: lineIndentRange)
            return false
        }

        private static func removingOneIndentLevel(from indent: String) -> String {
            if indent.hasSuffix(indentUnit) { return String(indent.dropLast(indentUnit.count)) }
            if indent.hasSuffix("\t") { return String(indent.dropLast()) }
            return ""
        }

        // MARK: - Folding

        /// Applies a fold as an edit to the region it changed, returning false
        /// when the text did not come from the same document and has to be
        /// swapped wholesale instead.
        func applyFold(to gutter: LineNumberRuler.Source?, in textView: NSTextView) -> Bool {
            guard let gutter, let previous = self.gutter,
                  previous.document.id == gutter.document.id,
                  let contentStorage = textView.textContentStorage,
                  let storage = contentStorage.textStorage,
                  let edit = gutter.projection.difference(from: previous.projection),
                  NSMaxRange(edit.range) <= storage.length
            else { return false }

            contentStorage.performEditingTransaction {
                storage.replaceCharacters(in: edit.range, with: edit.replacement)
            }
            return true
        }

        // MARK: - Highlighting

        /// Adopts a new set of highlighting inputs, repainting what is on
        /// screen only if they changed, and revealing the match jumped to.
        func apply(
            options: SyntaxHighlighter.Options,
            searchTerm: String,
            highlightedMatch: NSRange? = nil
        ) {
            let jumped = highlightedMatch != self.highlightedMatch
            guard jumped || options != self.options || searchTerm != self.searchTerm else { return }
            self.options = options
            self.searchTerm = searchTerm
            self.highlightedMatch = highlightedMatch
            invalidateParagraphs()

            if jumped, let match = highlightedMatch, let textView,
               NSMaxRange(match) <= textView.textStorage?.length ?? 0 {
                textView.scrollRangeToVisible(match)
            }
        }

        /// Discards the cached paragraphs so TextKit asks for them again. The
        /// document is marked as having changed attributes rather than content,
        /// which leaves the text, the selection and the undo stack alone.
        ///
        /// Only the visible paragraphs are rebuilt, however large the document.
        private func invalidateParagraphs() {
            guard let textView,
                  let contentStorage = textView.textContentStorage,
                  let storage = contentStorage.textStorage,
                  let layoutManager = textView.textLayoutManager
            else { return }

            contentStorage.performEditingTransaction {
                storage.edited(
                    .editedAttributes,
                    range: NSRange(location: 0, length: storage.length),
                    changeInLength: 0
                )
            }
            layoutManager.invalidateLayout(for: layoutManager.documentRange)
        }
    }
}

/// Supplies each paragraph already highlighted, as TextKit asks for it.
///
/// This is what keeps a large response cheap: the delegate is called for the
/// paragraphs being laid out -- a screenful -- rather than for the whole
/// document, so the cost of highlighting tracks the window and not the body.
/// Nothing here may touch `NSTextView.layoutManager`, which would drop the view
/// back to TextKit 1 and force a full-document layout.
extension CodeEditor.Coordinator: NSTextContentStorageDelegate {
    func textContentStorage(
        _ textContentStorage: NSTextContentStorage,
        textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        guard let storage = textContentStorage.textStorage else { return nil }

        // The jumped-to match is a position in the whole document; this
        // paragraph only knows about its own span of it.
        var current: NSRange?
        if let match = highlightedMatch {
            let overlap = NSIntersectionRange(match, range)
            if overlap.length > 0 {
                current = NSRange(
                    location: overlap.location - range.location, length: overlap.length
                )
            }
        }

        return NSTextParagraph(
            attributedString: SyntaxHighlighter.attributedParagraph(
                for: storage.attributedSubstring(from: range).string,
                options: options,
                style: style,
                searchTerm: searchTerm,
                currentMatch: current
            )
        )
    }
}

/// A `CodeEditor` with a placeholder shown while it is empty, since
/// `NSTextView` has no placeholder of its own.
struct PlaceholderCodeEditor: View {
    @Binding var text: String
    var options: SyntaxHighlighter.Options = .plain
    var isEditable: Bool = true
    var placeholder: String = ""
    var searchTerm: String = ""
    var indentsAutomatically: Bool = true

    var body: some View {
        CodeEditor(
            text: $text,
            options: options,
            isEditable: isEditable,
            searchTerm: searchTerm,
            indentsAutomatically: indentsAutomatically
        )
        .overlay(alignment: .topLeading) {
            if text.isEmpty, !placeholder.isEmpty {
                Text(placeholder)
                    .font(.system(size: NSFont.systemFontSize, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }
}
