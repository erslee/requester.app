import Foundation

/// Splits a shell command into arguments the way bash would, so a pasted curl
/// command yields exactly the strings curl itself received.
///
/// Three quoting styles, each with different escape rules:
/// - `'single'` — everything literal, no escapes at all
/// - `"double"` — only `\" \\ \$ \`` are escapes; other backslashes stay
/// - `$'ansi-c'` — full escape decoding (`\n`, `\t`, `\uXXXX`, `\xNN`, …)
///
/// The last one is what Chrome's "Copy as cURL" emits for any body containing a
/// quote or newline, so getting it wrong corrupts the most commonly pasted
/// commands.
nonisolated enum ShellTokenizer {
    static func tokenize(_ input: String) -> [String] {
        let characters = Array(input)
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        var index = 0

        while index < characters.count {
            let character = characters[index]

            // $'...' -- ANSI-C quoting, escapes decoded.
            if character == "$", index + 1 < characters.count, characters[index + 1] == "'" {
                let (decoded, next) = decodeANSIC(characters, from: index + 2)
                current += decoded
                hasCurrent = true
                index = next
                continue
            }

            if character == "'" {
                let (literal, next) = readSingleQuoted(characters, from: index + 1)
                current += literal
                hasCurrent = true
                index = next
                continue
            }

            if character == "\"" {
                let (text, next) = readDoubleQuoted(characters, from: index + 1)
                current += text
                hasCurrent = true
                index = next
                continue
            }

            if character == "\\", index + 1 < characters.count {
                current.append(characters[index + 1])
                hasCurrent = true
                index += 2
                continue
            }

            if character.isWhitespace {
                if hasCurrent {
                    tokens.append(current)
                    current = ""
                    hasCurrent = false
                }
                index += 1
                continue
            }

            current.append(character)
            hasCurrent = true
            index += 1
        }

        if hasCurrent { tokens.append(current) }
        return tokens
    }

    // MARK: - Quoting styles

    private static func readSingleQuoted(
        _ characters: [Character], from start: Int
    ) -> (String, Int) {
        var result = ""
        var index = start
        while index < characters.count, characters[index] != "'" {
            result.append(characters[index])
            index += 1
        }
        return (result, min(index + 1, characters.count))
    }

    private static func readDoubleQuoted(
        _ characters: [Character], from start: Int
    ) -> (String, Int) {
        var result = ""
        var index = start
        while index < characters.count, characters[index] != "\"" {
            guard characters[index] == "\\", index + 1 < characters.count else {
                result.append(characters[index])
                index += 1
                continue
            }
            let escaped = characters[index + 1]
            // Inside double quotes bash only treats these four as escapes; for
            // anything else the backslash is passed through literally, which is
            // what keeps a JSON `\n` intact.
            if escaped == "\"" || escaped == "\\" || escaped == "$" || escaped == "`" {
                result.append(escaped)
            } else {
                result.append(characters[index])
                result.append(escaped)
            }
            index += 2
        }
        return (result, min(index + 1, characters.count))
    }

    /// Decodes the body of a `$'...'` string.
    ///
    /// Note what this does to a doubled backslash: `\\n` becomes `\n` -- a
    /// backslash followed by `n`, which is exactly the two-character escape JSON
    /// needs inside a string. Leaving it undecoded is what makes a pasted
    /// GraphQL body fail to parse at the server.
    private static func decodeANSIC(
        _ characters: [Character], from start: Int
    ) -> (String, Int) {
        var result = ""
        var index = start

        while index < characters.count {
            let character = characters[index]
            if character == "'" { return (result, index + 1) }

            guard character == "\\", index + 1 < characters.count else {
                result.append(character)
                index += 1
                continue
            }

            let escaped = characters[index + 1]
            index += 2

            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "a": result.append("\u{07}")
            case "b": result.append("\u{08}")
            case "f": result.append("\u{0C}")
            case "v": result.append("\u{0B}")
            case "e", "E": result.append("\u{1B}")
            case "\\": result.append("\\")
            case "'": result.append("'")
            case "\"": result.append("\"")
            case "?": result.append("?")
            case "u", "U":
                let (scalar, next) = readHexScalar(
                    characters, from: index, maxDigits: escaped == "u" ? 4 : 8
                )
                if let scalar { result.append(scalar) }
                index = next
            case "x":
                let (scalar, next) = readHexScalar(characters, from: index, maxDigits: 2)
                if let scalar { result.append(scalar) }
                index = next
            case "0"..."7":
                let (scalar, next) = readOctalScalar(characters, from: index - 1)
                if let scalar { result.append(scalar) }
                index = next
            default:
                // Not an escape bash recognises: the backslash survives.
                result.append("\\")
                result.append(escaped)
            }
        }
        return (result, index)
    }

    private static func readHexScalar(
        _ characters: [Character], from start: Int, maxDigits: Int
    ) -> (Character?, Int) {
        var digits = ""
        var index = start
        while digits.count < maxDigits, index < characters.count, characters[index].isHexDigit {
            digits.append(characters[index])
            index += 1
        }
        guard let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) else {
            return (nil, index)
        }
        return (Character(scalar), index)
    }

    private static func readOctalScalar(
        _ characters: [Character], from start: Int
    ) -> (Character?, Int) {
        var digits = ""
        var index = start
        while digits.count < 3, index < characters.count,
              let digit = characters[index].wholeNumberValue, (0...7).contains(digit) {
            digits.append(characters[index])
            index += 1
        }
        guard let value = UInt32(digits, radix: 8), let scalar = Unicode.Scalar(value) else {
            return (nil, index)
        }
        return (Character(scalar), index)
    }
}
