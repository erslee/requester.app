import Foundation

/// Reformats JSON for reading.
///
/// The formatting itself is `FoldableText.json`, which walks the bytes rather
/// than parsing: a large response body is truncated for display, and truncated
/// JSON does not parse -- a formatter that only handles complete input would
/// fail on exactly the responses that most need reformatting. That pass also
/// indexes the lines and pairs the brackets, which is what the response viewer
/// numbers and collapses; callers wanting only the text come through here.
nonisolated enum JSONFormatter {
    static let indent = "  "

    /// Formats only if the text looks like JSON, so it is safe to apply to any
    /// response body.
    static func prettyPrintedIfJSON(_ text: String) -> String {
        looksLikeJSON(text) ? prettyPrinted(text) : text
    }

    static func looksLikeJSON(_ text: String) -> Bool {
        let start = text.prefix(512).trimmingCharacters(in: .whitespacesAndNewlines)
        return start.hasPrefix("{") || start.hasPrefix("[")
    }

    static func prettyPrinted(_ json: String) -> String {
        FoldableText.json(json).text
    }
}
