import Foundation

/// Reformats JSON for reading.
///
/// Deliberately not `JSONSerialization`: a large response body is truncated for
/// display, and truncated JSON does not parse -- a formatter that only handles
/// complete input would fail on exactly the responses that most need
/// reformatting. This walks the text instead, so a body cut off partway still
/// comes out readable, and it costs one pass rather than a parse plus a
/// re-serialise.
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
        var result = ""
        result.reserveCapacity(json.count + json.count / 2)

        var depth = 0
        var isInString = false
        var isEscaped = false

        /// An opening bracket does not know yet whether it is empty, so the
        /// newline after it waits for the next meaningful character.
        var isAwaitingFirstMember = false

        func appendLine(at depth: Int) {
            result.append("\n")
            result.append(String(repeating: Self.indent, count: max(depth, 0)))
        }

        for character in json {
            if isInString {
                result.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
                continue
            }

            // The input's own whitespace is dropped; this function owns layout.
            if character.isWhitespace { continue }

            if isAwaitingFirstMember {
                isAwaitingFirstMember = false
                if character == "}" || character == "]" {
                    // Nothing inside: keep it on one line as {} or [].
                    depth -= 1
                    result.append(character)
                    continue
                }
                appendLine(at: depth)
            }

            switch character {
            case "{", "[":
                result.append(character)
                depth += 1
                isAwaitingFirstMember = true
            case "}", "]":
                depth -= 1
                appendLine(at: depth)
                result.append(character)
            case ",":
                result.append(character)
                appendLine(at: depth)
            case ":":
                result.append(": ")
            case "\"":
                isInString = true
                result.append(character)
            default:
                result.append(character)
            }
        }

        return result
    }
}
