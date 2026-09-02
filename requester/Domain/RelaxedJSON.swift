import Foundation

/// Turns a JavaScript object literal into JSON.
///
/// The text people actually have to hand is rarely JSON: it has been copied out
/// of a console log, a debugger, a test fixture, or someone's source, and so it
/// carries bare keys, single quotes, trailing commas and comments --
///
///     { projectId: '708000c9', units: [ 'A1.2a' ], /* note */ }
///
/// A character scanner rather than a set of regexes, for the same reason
/// `CurlParser` is one: every rule here has to know whether it is inside a
/// string, and a regex does not. Quoting a bare key is only safe if `id:` in
/// `{"note": "id: 4"}` is left alone.
///
/// The result is only ever offered when it *parses*. Anything this cannot make
/// sense of -- a value that is a JS expression, an unterminated string, a
/// fragment that is not object- or array-shaped -- returns nil, and the caller
/// keeps the original text. Silently mangling a paste would be far worse than
/// not helping with it.
nonisolated enum RelaxedJSON {
    /// Formatted JSON for a JS-style object literal, or nil to leave the text
    /// alone.
    ///
    /// Text that is *already* JSON also returns nil: it needs no repair, and
    /// reformatting a body someone deliberately pasted minified would be a
    /// change they did not ask for.
    ///
    /// "Already JSON" is decided by the scanner finding nothing to change, not
    /// by asking a parser. `JSONSerialization` is more forgiving than the
    /// format it is named after -- it accepts a trailing comma -- so a body it
    /// waved through could still be rejected by the server it was sent to.
    static func repaired(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }

        let candidate = normalized(trimmed)
        guard candidate != trimmed, parses(candidate) else { return nil }
        return JSONFormatter.prettyPrinted(candidate)
    }

    private static func parses(_ text: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
    }

    // MARK: - Scanning

    private static func normalized(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        var index = 0

        while index < characters.count {
            let character = characters[index]

            // Quoted runs are copied across as JSON strings and never inspected
            // further -- their contents are content, not syntax.
            if character == "\"" || character == "'" {
                let (string, next) = readString(characters, from: index, quote: character)
                output += string
                index = next
                continue
            }

            if isCommentStart(characters, at: index) {
                index = endOfComment(characters, from: index)
                continue
            }

            // A trailing comma: legal in JS, not in JSON.
            if character == ",", nextSignificant(characters, from: index + 1)
                .map({ $0 == "}" || $0 == "]" }) ?? true {
                index += 1
                continue
            }

            if isWordCharacter(character) {
                let (word, next) = readWord(characters, from: index)
                // Only a word used as a key is quoted. Everything else -- a
                // number, `true`, `null` -- is already valid JSON as it stands,
                // and anything that is not will fail the parse check above.
                let isKey = nextSignificant(characters, from: next) == ":"
                output += isKey ? "\"\(word)\"" : word
                index = next
                continue
            }

            output.append(character)
            index += 1
        }

        return output
    }

    /// Reads a quoted run and re-emits it double-quoted.
    ///
    /// Escapes are rewritten rather than copied: JSON has no `\'`, so it loses
    /// its backslash, and a `"` that was literal inside single quotes gains
    /// one. Every other escape is passed through untouched -- `\n` and `\uXXXX`
    /// mean the same thing in both languages, and re-encoding them would only
    /// be a chance to get them wrong.
    private static func readString(
        _ characters: [Character], from start: Int, quote: Character
    ) -> (String, Int) {
        var content = ""
        var index = start + 1

        while index < characters.count, characters[index] != quote {
            if characters[index] == "\\", index + 1 < characters.count {
                let escaped = characters[index + 1]
                content += escaped == "'" ? "'" : "\\\(escaped)"
                index += 2
                continue
            }
            // Only reachable inside a single-quoted run; in a double-quoted one
            // this character would have ended the string.
            content += characters[index] == "\"" ? "\\\"" : String(characters[index])
            index += 1
        }

        return ("\"\(content)\"", min(index + 1, characters.count))
    }

    /// Bare keys, numbers and keywords all look the same to the scanner; which
    /// one it is falls out of whether a `:` follows. `.`, `-` and `+` are in
    /// here so a number is read whole rather than in pieces.
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "_$.-+".contains(character)
    }

    private static func readWord(
        _ characters: [Character], from start: Int
    ) -> (String, Int) {
        var index = start
        while index < characters.count, isWordCharacter(characters[index]) { index += 1 }
        return (String(characters[start..<index]), index)
    }

    // MARK: - Comments

    private static func isCommentStart(_ characters: [Character], at index: Int) -> Bool {
        characters[index] == "/" && index + 1 < characters.count
            && (characters[index + 1] == "/" || characters[index + 1] == "*")
    }

    /// The index just past a comment. A line comment stops *at* its newline
    /// rather than after it, so the lines the reader wrote stay lines.
    private static func endOfComment(_ characters: [Character], from start: Int) -> Int {
        var index = start + 2
        guard characters[start + 1] == "*" else {
            while index < characters.count, characters[index] != "\n" { index += 1 }
            return index
        }
        while index + 1 < characters.count,
              !(characters[index] == "*" && characters[index + 1] == "/") {
            index += 1
        }
        return min(index + 2, characters.count)
    }

    /// The next character that carries meaning, skipping whitespace and
    /// comments. Deciding both "is this word a key?" and "is this comma
    /// trailing?" needs to look past a comment sitting between the two.
    private static func nextSignificant(
        _ characters: [Character], from start: Int
    ) -> Character? {
        var index = start
        while index < characters.count {
            if characters[index].isWhitespace {
                index += 1
                continue
            }
            if isCommentStart(characters, at: index) {
                index = endOfComment(characters, from: index)
                continue
            }
            return characters[index]
        }
        return nil
    }
}
