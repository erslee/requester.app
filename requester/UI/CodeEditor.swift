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
    var gutter: LineNumberGutter.Source?

    /// Called with the source line whose fold triangle was clicked.
    var onToggleFold: ((Int) -> Void)?

    /// Off means long lines scroll sideways instead of wrapping, which is what
    /// keeps one line to one gutter row.
    var wrapsLines: Bool = true

    /// How wide the widest line is, in characters. The font is monospaced, so
    /// this is the whole document's width without laying any of it out.
    ///
    /// Passed in rather than read off the gutter: a view can want sideways
    /// scrolling and no line numbers at all -- the raw view of a response is
    /// exactly that -- and deriving the width from the gutter left that case
    /// wrapping whatever the toggle said.
    var longestLineLength: Int = 0

    /// The search match the reader last jumped to. It is scrolled into view and
    /// shaded apart from the others.
    var highlightedMatch: NSRange?

    func makeNSView(context: Context) -> GutteredEditor {
        let editor = GutteredEditor(isEditable: isEditable)
        let textView = editor.textView
        textView.delegate = context.coordinator
        textView.repairsPastedJSON = options.json
        editor.setWraps(wrapsLines, unwrappedWidth: unwrappedWidth)

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
        context.coordinator.displayedText = text
        syncGutter(on: editor, coordinator: context.coordinator)
        return editor
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
        _ proposal: ProposedViewSize, nsView: GutteredEditor, context: Context
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

    func updateNSView(_ editor: GutteredEditor, context: Context) {
        let textView = editor.textView
        context.coordinator.text = $text
        context.coordinator.indentsAutomatically = indentsAutomatically
        // The body's type picker can switch to JSON while the editor is open.
        textView.repairsPastedJSON = options.json
        context.coordinator.onToggleFold = onToggleFold
        textView.isEditable = isEditable
        textView.allowsUndo = isEditable
        editor.setWraps(wrapsLines, unwrappedWidth: unwrappedWidth)

        // Only push text in when it changed outside the editor (a request was
        // loaded, a curl command imported, a block was collapsed) -- otherwise
        // typing would fight with the binding and reset the cursor.
        if text != context.coordinator.displayedText {
            let selection = textView.selectedRange()
            // Collapsing a block is an edit to one region, not a new document.
            // Applying it as one keeps the reader where they were.
            if !context.coordinator.applyFold(to: gutter, in: textView) {
                textView.string = text
                textView.setSelectedRange(
                    NSRange(location: min(selection.location, text.utf16.count), length: 0)
                )
            }
            context.coordinator.displayedText = text
        }
        context.coordinator.gutter = gutter
        context.coordinator.apply(
            options: options, searchTerm: searchTerm, highlightedMatch: highlightedMatch
        )

        // The gutter draws from the projection, so it is refreshed whenever the
        // text it numbers might have moved. Redrawing costs a screenful.
        syncGutter(on: editor, coordinator: context.coordinator)
    }

    /// The fold triangles report to the coordinator, which is what holds the
    /// caller's handler. Weakly, since the gutter outlives any one update.
    private func syncGutter(on editor: GutteredEditor, coordinator: Coordinator) {
        editor.setGutter(gutter) { [weak coordinator] line in
            coordinator?.onToggleFold?(line)
        }
    }

    /// Beyond this, a line is wrapped whatever the caller asked for. Only the
    /// minified case reaches it -- a whole body on one line, which would mean a
    /// text view tens of millions of points wide. A bounded container stays
    /// lazy at any width short of that, so the limit is deliberately far above
    /// anything a formatted response produces.
    static let widestUnwrappedLine: CGFloat = 1_000_000

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
        Self.unwrappedWidth(longestLineLength: longestLineLength)
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

        /// What the text view is showing, as the caller last handed it over.
        ///
        /// The check that decides whether to push new text compares against
        /// this rather than against `NSTextView.string`. That property is a
        /// Swift `String` lazily bridged from the storage's
        /// `NSBigMutableString`, and comparing a bridged string with a native
        /// one cannot use `memcmp`: Swift falls back to a Unicode-normalising
        /// walk, one `-[NSBigMutableString characterAtIndex:]` message per
        /// character. On a megabyte response that is seconds of main-thread
        /// work -- and `updateNSView` runs on every SwiftUI update, including
        /// the one AppKit raises when the window becomes active, which is why
        /// switching back to the app used to hang.
        ///
        /// Held as the very value the caller passed, so the usual case is the
        /// same instance twice and the comparison is a pointer check.
        var displayedText = ""

        /// The projection currently on screen, needed to read a scroll position
        /// as a line of the original and to put it back afterwards.
        var gutter: LineNumberGutter.Source?

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
            // The same instance goes into the binding and into `displayedText`,
            // so the next update compares them by pointer.
            let typed = textView.string
            displayedText = typed
            text.wrappedValue = typed
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
        func applyFold(to gutter: LineNumberGutter.Source?, in textView: NSTextView) -> Bool {
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

/// The AppKit half of the editor: a text view in a scroll view, with the line
/// number gutter as its neighbour rather than as a layer over the top of it.
///
/// The layout is the whole point of the class. AppKit's own answer -- an
/// `NSRulerView` -- reserves the gutter's width as a *left content inset* on a
/// clip view that stays full width, so the numbers are painted over the text
/// and the text only clears them at the one scroll position where the document
/// sits at minus that inset. Sideways scrolling leaves it elsewhere, and so
/// does any resize that re-clamps the scroll offset, which is how the first
/// characters of every line kept disappearing under the numbers. Here the
/// scroll view is genuinely narrower, so there is no offset at which the two
/// can overlap and no arithmetic keeping them apart.
///
/// Free of SwiftUI, so the geometry it produces can be built and measured in a
/// test.
final class GutteredEditor: NSView {
    let scrollView: NSScrollView
    let textView: PastingTextView

    /// Created on demand and kept afterwards, since a body switched to Raw and
    /// back wants the same gutter rather than a new one. Nil source is what
    /// takes its width away.
    private var gutter: LineNumberGutter?

    /// What `setWraps` was last told, re-applied on every layout: an unwrapped
    /// text view does not follow its clip view's width, so a window growing
    /// wider than the document would otherwise leave a dead strip beside it.
    private var wrapsLines = true
    private var unwrappedWidth: CGFloat = 0

    /// Which way the text was last actually laid out, so a layout pass that
    /// changes neither the mode nor the width does nothing at all. Nil until
    /// the first pass. Read as "what is on screen", against `wrapsLines`'s
    /// "what has been asked for".
    private var appliedWrapped: Bool?

    init(isEditable: Bool) {
        textView = PastingTextView()
        textView.isEditable = isEditable
        textView.isRichText = false
        textView.allowsUndo = isEditable
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = CodeEditor.font
        textView.textContainerInset = CGSize(width: 6, height: 8)
        textView.drawsBackground = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true

        scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        super.init(frame: .zero)
        addSubview(scrollView)

        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.defaultLow, for: axis)
            setContentCompressionResistancePriority(.defaultLow, for: axis)
        }

        // The scroll view re-tiles for reasons of its own -- a scroller style
        // change when a mouse is plugged in, or the system setting switched
        // while the window is open -- which moves the clip view the gutter is
        // matched to. An `NSRulerView` was tiled along with it and got this
        // free; a sibling has to hear about it.
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewDidResize),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )
    }

    /// Ignored while laying out, where the clip view is being moved on purpose
    /// and the gutter is placed against its final position anyway.
    @objc private func clipViewDidResize() {
        guard !isLayingOut else { return }
        needsLayout = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    private var isLayingOut = false

    /// The gutter takes the width it needs from the left, the scroll view takes
    /// the rest. The gutter is matched to the *clip* view rather than to the
    /// whole scroll view, so it stops where the text does instead of running
    /// down beside a horizontal scroller.
    ///
    /// Wrapping is settled before the gutter is placed, because turning it off
    /// is what puts that horizontal scroller there: measuring the clip view
    /// first would size the gutter against a viewport a scroller's height taller
    /// than the one the text ends up in.
    override func layout() {
        super.layout()
        isLayingOut = true
        defer { isLayingOut = false }

        let width = gutter?.thickness ?? 0
        scrollView.frame = NSRect(
            x: width, y: 0, width: max(bounds.width - width, 0), height: bounds.height
        )
        applyWrapping()

        if let gutter {
            let content = convert(scrollView.contentView.frame, from: scrollView)
            gutter.frame = NSRect(
                x: 0, y: content.minY, width: width, height: content.height
            )
        }
    }

    // MARK: - Gutter

    /// Brings the gutter into line with what the caller is asking for.
    ///
    /// Both directions matter, and neither is a one-off at construction time:
    /// a response switched to Raw stops wanting one, and a body that is only
    /// JSON on the second send starts wanting one.
    func setGutter(_ source: LineNumberGutter.Source?, onToggleFold: @escaping (Int) -> Void) {
        guard source != nil || gutter != nil else { return }

        let gutter = self.gutter ?? {
            let gutter = LineNumberGutter(scrollView: scrollView)
            addSubview(gutter)
            self.gutter = gutter
            return gutter
        }()

        gutter.onToggleFold = onToggleFold
        gutter.isHidden = source == nil
        // Assigning the source is what asks for a re-layout, and only when the
        // width it needs actually changed.
        gutter.source = source
    }

    // MARK: - Wrapping

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
    func setWraps(_ wraps: Bool, unwrappedWidth: CGFloat) {
        guard wraps != wrapsLines || unwrappedWidth != self.unwrappedWidth else { return }
        wrapsLines = wraps
        self.unwrappedWidth = unwrappedWidth
        // Through a layout pass rather than straight to `applyWrapping`: the
        // toggle can add or remove the horizontal scroller, and the gutter has
        // to be re-measured against what that leaves of the clip view.
        needsLayout = true
    }

    private func applyWrapping() {
        guard let container = textView.textContainer else { return }
        let wrapped = wrapsLines || unwrappedWidth > CodeEditor.widestUnwrappedLine
        // The visible width, now that the gutter is no longer taken out of it
        // as an inset -- so a wrapped line breaks where the reader can see it
        // break, rather than a gutter's width further right.
        let width = wrapped
            ? scrollView.contentSize.width
            : max(unwrappedWidth, scrollView.contentSize.width)

        // Against what was last applied, not against `isHorizontallyResizable`
        // -- which is assigned false unconditionally below and defaults to
        // false, so it only ever restated `!wrapped` and left the unwrapped
        // case re-running the whole body on every pass.
        guard appliedWrapped != wrapped || abs(textView.frame.width - width) > 0.5
        else { return }
        appliedWrapped = wrapped

        container.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        // A wrapped view follows the scroll view's width; a widened one must
        // not be pulled back to it on the next resize.
        textView.autoresizingMask = wrapped ? [.width] : []
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        scrollView.hasHorizontalScroller = !wrapped
    }
}

/// An `NSTextView` that tidies up what is pasted into it.
///
/// The text people have to hand for a JSON body is very often not JSON: it has
/// been copied out of a console log or a debugger, and arrives as a JavaScript
/// object literal. Repairing it here rather than behind a button means it is
/// already right by the time it is read back, and there is no second step to
/// forget.
///
/// A subclass because `paste(_:)` is the only place that knows a paste is what
/// happened. `NSTextViewDelegate` sees the insertion, but not that the text
/// came from the pasteboard -- and typing a `{` must not trigger any of this.
final class PastingTextView: NSTextView {
    /// Set by `CodeEditor` for the editors whose content is JSON: the raw body
    /// when its type is JSON, and the GraphQL variables box.
    var repairsPastedJSON = false

    override func paste(_ sender: Any?) {
        guard repairsPastedJSON,
              let pasted = NSPasteboard.general.string(forType: .string),
              let repaired = RelaxedJSON.repaired(pasted)
        else { return super.paste(sender) }

        // Inserted rather than assigned, so it lands at the insertion point,
        // replaces the selection, and is a single undo step like any other
        // paste. `RelaxedJSON` returns nil for anything it cannot make sense
        // of, so the fall-through above is the normal path.
        insertText(repaired, replacementRange: selectedRange())
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
