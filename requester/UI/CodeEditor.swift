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

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = Self.font
        textView.textContainerInset = CGSize(width: 6, height: 8)
        textView.drawsBackground = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            scrollView.setContentHuggingPriority(.defaultLow, for: axis)
            scrollView.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }

        context.coordinator.textView = textView
        textView.string = text
        context.coordinator.rehighlight(options: options, searchTerm: searchTerm)
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
        textView.isEditable = isEditable

        // Only push text in when it changed outside the editor (a request was
        // loaded, a curl command imported) -- otherwise typing would fight
        // with the binding and reset the cursor.
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(
                NSRange(location: min(selection.location, text.utf16.count), length: 0)
            )
        }
        context.coordinator.rehighlight(options: options, searchTerm: searchTerm)
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
        weak var textView: NSTextView?

        /// What the current attributes were computed from. `updateNSView` runs
        /// on every surrounding state change -- a send starting, a tab
        /// switching -- and re-attributing a large response body each time is
        /// wasted work on the main thread.
        private struct Inputs: Equatable {
            var length: Int
            var hash: Int
            var options: SyntaxHighlighter.Options
            var searchTerm: String
        }

        private var lastInputs: Inputs?

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

        func rehighlight(options: SyntaxHighlighter.Options, searchTerm: String) {
            guard let storage = textView?.textStorage else { return }

            let inputs = Inputs(
                length: storage.length,
                hash: storage.string.hashValue,
                options: options,
                searchTerm: searchTerm
            )
            guard inputs != lastInputs else { return }
            lastInputs = inputs

            SyntaxHighlighter.apply(
                to: storage,
                options: options,
                font: CodeEditor.font,
                searchTerm: searchTerm
            )
        }
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
