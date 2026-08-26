import AppKit

/// Lightweight, line-at-a-time highlighting shared by the code editors and the
/// read-only response body.
///
/// Two independent passes, either or both of which a caller can ask for:
/// - JSON tokens (strings, keys, numbers, `true`/`false`/`null`)
/// - `{{name}}` placeholders, green when the name is a known project variable
///   and red when it is not and would be sent through literally
nonisolated enum SyntaxHighlighter {
    struct Span {
        var range: NSRange
        var color: NSColor
        var isBold: Bool
    }

    struct Options: Equatable {
        var json: Bool = false
        var graphQL: Bool = false
        var knownVariableNames: Set<String>?

        /// No highlighting: a monospaced editor with nothing coloured.
        static let plain = Options()

        var highlightsAnything: Bool { json || graphQL || knownVariableNames != nil }
    }

    private static let stringPattern = try! NSRegularExpression(
        pattern: #""(?:[^"\\]|\\.)*""#
    )
    private static let keyPattern = try! NSRegularExpression(
        pattern: #""(?:[^"\\]|\\.)*"\s*(?=:)"#
    )
    private static let numberPattern = try! NSRegularExpression(
        pattern: #"(?<![\w.])-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#
    )
    private static let keywordPattern = try! NSRegularExpression(
        pattern: #"\b(?:true|false|null)\b"#
    )
    private static let variablePattern = try! NSRegularExpression(
        pattern: #"\{\{\s*([A-Za-z0-9_.\-]+)\s*\}\}"#
    )

    // GraphQL
    /// Operation keywords only. The schema-definition words -- `type`, `input`,
    /// `enum`, `union` and friends -- are deliberately absent: this editor holds
    /// queries, where those appear as ordinary field and argument names.
    /// Colouring `imageryLibrary(input: $x)` as a keyword is worse than leaving
    /// it plain.
    private static let graphQLKeywordPattern = try! NSRegularExpression(
        pattern: #"\b(?:query|mutation|subscription|fragment|on)\b"#
    )
    private static let graphQLTypePattern = try! NSRegularExpression(
        pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#
    )
    private static let graphQLVariablePattern = try! NSRegularExpression(
        pattern: #"\$[A-Za-z_][A-Za-z0-9_]*"#
    )
    private static let graphQLDirectivePattern = try! NSRegularExpression(
        pattern: #"@[A-Za-z_][A-Za-z0-9_]*"#
    )
    private static let graphQLCommentPattern = try! NSRegularExpression(pattern: #"#[^\n]*"#)

    /// Spans for one line, in application order -- later spans win, which is
    /// how keys beat plain strings and variables beat everything.
    static func spans(in line: String, options: Options) -> [Span] {
        var spans: [Span] = []
        let full = NSRange(line.startIndex..., in: line)

        if options.json {
            append(stringPattern, in: line, full, .jsonString, bold: false, to: &spans)
            append(numberPattern, in: line, full, .jsonNumber, bold: false, to: &spans)
            append(keywordPattern, in: line, full, .jsonKeyword, bold: true, to: &spans)
            append(keyPattern, in: line, full, .jsonKey, bold: true, to: &spans)
        }

        if options.graphQL {
            // Order is priority: each pass overwrites the last, so a keyword
            // inside a string loses to the string, and a comment wins outright.
            append(graphQLTypePattern, in: line, full, .graphQLType, bold: false, to: &spans)
            append(numberPattern, in: line, full, .jsonNumber, bold: false, to: &spans)
            append(keywordPattern, in: line, full, .jsonKeyword, bold: true, to: &spans)
            append(graphQLKeywordPattern, in: line, full, .jsonKeyword, bold: true, to: &spans)
            append(graphQLVariablePattern, in: line, full, .graphQLVariable, bold: true, to: &spans)
            append(graphQLDirectivePattern, in: line, full, .graphQLDirective, bold: false, to: &spans)
            append(stringPattern, in: line, full, .jsonString, bold: false, to: &spans)
            append(graphQLCommentPattern, in: line, full, .comment, bold: false, to: &spans)
        }

        if let knownNames = options.knownVariableNames {
            variablePattern.enumerateMatches(in: line, range: full) { match, _, _ in
                guard let match, let nameRange = Range(match.range(at: 1), in: line) else { return }
                let isKnown = knownNames.contains(String(line[nameRange]))
                spans.append(
                    Span(
                        range: match.range,
                        color: isKnown ? .variableValid : .variableInvalid,
                        isBold: true
                    )
                )
            }
        }

        return spans
    }

    private static func append(
        _ pattern: NSRegularExpression,
        in line: String,
        _ range: NSRange,
        _ color: NSColor,
        bold: Bool,
        to spans: inout [Span]
    ) {
        pattern.enumerateMatches(in: line, range: range) { match, _, _ in
            guard let match else { return }
            spans.append(Span(range: match.range, color: color, isBold: bold))
        }
    }

    /// Applies highlighting to every line of `storage`, plus optional
    /// highlighting of search matches on top.
    static func apply(
        to storage: NSTextStorage,
        options: Options,
        font: NSFont,
        baseColor: NSColor = .labelColor,
        searchTerm: String = ""
    ) {
        let text = storage.string
        let fullRange = NSRange(location: 0, length: storage.length)

        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: baseColor], range: fullRange)
        storage.removeAttribute(.backgroundColor, range: fullRange)

        if options.highlightsAnything {
            let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            (text as NSString).enumerateSubstrings(
                in: fullRange, options: .byLines
            ) { line, lineRange, _, _ in
                guard let line else { return }
                for span in spans(in: line, options: options) {
                    let absolute = NSRange(
                        location: lineRange.location + span.range.location,
                        length: span.range.length
                    )
                    guard NSMaxRange(absolute) <= storage.length else { continue }
                    storage.addAttribute(.foregroundColor, value: span.color, range: absolute)
                    if span.isBold {
                        storage.addAttribute(.font, value: boldFont, range: absolute)
                    }
                }
            }
        }

        if !searchTerm.isEmpty {
            var searchRange = fullRange
            while searchRange.length > 0 {
                let found = (text as NSString).range(
                    of: searchTerm, options: .caseInsensitive, range: searchRange
                )
                guard found.location != NSNotFound else { break }
                storage.addAttribute(
                    .backgroundColor, value: NSColor.findHighlightColor, range: found
                )
                let next = NSMaxRange(found)
                searchRange = NSRange(location: next, length: fullRange.length - next)
            }
        }

        storage.endEditing()
    }
}

nonisolated extension NSColor {
    static let jsonString = NSColor(srgbRed: 0.18, green: 0.55, blue: 0.34, alpha: 1)
    static let jsonKey = NSColor(srgbRed: 0.19, green: 0.47, blue: 0.78, alpha: 1)
    static let jsonNumber = NSColor(srgbRed: 0.80, green: 0.48, blue: 0.00, alpha: 1)
    static let jsonKeyword = NSColor(srgbRed: 0.55, green: 0.36, blue: 0.96, alpha: 1)
    static let variableValid = NSColor(srgbRed: 0.18, green: 0.55, blue: 0.34, alpha: 1)
    static let variableInvalid = NSColor(srgbRed: 0.86, green: 0.15, blue: 0.15, alpha: 1)
    static let graphQLType = NSColor(srgbRed: 0.19, green: 0.47, blue: 0.78, alpha: 1)
    // Distinct from numbers and keywords: sharing a colour with those made
    // `$variables` and `@directives` impossible to pick out of a query.
    static let graphQLVariable = NSColor(srgbRed: 0.05, green: 0.58, blue: 0.62, alpha: 1)
    static let graphQLDirective = NSColor(srgbRed: 0.78, green: 0.24, blue: 0.53, alpha: 1)
    static let comment = NSColor.secondaryLabelColor
}
