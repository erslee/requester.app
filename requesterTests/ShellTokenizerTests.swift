import Testing
@testable import requester

/// Quoting is where a pasted curl command goes wrong silently: the request is
/// built from strings that look almost right and the server rejects them.
struct ShellTokenizerTests {
    @Test func splitsOnUnquotedWhitespaceOnly() {
        #expect(ShellTokenizer.tokenize("curl -X POST https://x.com") ==
            ["curl", "-X", "POST", "https://x.com"])
        #expect(ShellTokenizer.tokenize("curl 'a b' \"c d\"") == ["curl", "a b", "c d"])
    }

    @Test func treatsEverythingInSingleQuotesAsLiteral() {
        // A backslash inside single quotes is a backslash, not an escape.
        #expect(ShellTokenizer.tokenize(#"-d 'a\nb'"#) == ["-d", #"a\nb"#])
        #expect(ShellTokenizer.tokenize(#"-H 'sec-ch-ua: "Not=A?Brand";v="99"'"#)
            == ["-H", #"sec-ch-ua: "Not=A?Brand";v="99""#])
    }

    @Test func escapesOnlyTheFourCharactersBashDoesInDoubleQuotes() {
        // \" and \\ collapse; \n keeps its backslash, which is what leaves a
        // JSON escape intact inside a double-quoted body.
        #expect(ShellTokenizer.tokenize(#""say \"hi\"""#) == [#"say "hi""#])
        #expect(ShellTokenizer.tokenize(#""a\\b""#) == [#"a\b"#])
        #expect(ShellTokenizer.tokenize(#""line\nbreak""#) == [#"line\nbreak"#])
    }

    /// `$'...'` is what Chrome emits for any body containing a quote or a
    /// newline. Not decoding it leaves a stray `$` on the front and every
    /// escape unprocessed.
    @Test func decodesANSICQuoting() {
        #expect(ShellTokenizer.tokenize("$'plain'") == ["plain"])
        #expect(ShellTokenizer.tokenize(#"$'a\tb'"#) == ["a\tb"])
        #expect(ShellTokenizer.tokenize(#"$'it\'s'"#) == ["it's"])

        // A doubled backslash becomes one, giving JSON its two-character escape.
        #expect(ShellTokenizer.tokenize(#"$'a\\nb'"#) == [#"a\nb"#])

        // Numeric escapes
        #expect(ShellTokenizer.tokenize(#"$'!'"#) == ["!"])
        #expect(ShellTokenizer.tokenize(#"$'\x41'"#) == ["A"])
        #expect(ShellTokenizer.tokenize(#"$'\101'"#) == ["A"])

        // An unrecognised escape keeps its backslash, as bash does.
        #expect(ShellTokenizer.tokenize(#"$'\q'"#) == [#"\q"#])
    }

    @Test func closesAnUnterminatedQuoteAtTheEnd() {
        // A truncated paste should still yield the text, not lose it.
        #expect(ShellTokenizer.tokenize("-d 'unterminated") == ["-d", "unterminated"])
        #expect(ShellTokenizer.tokenize("$'unterminated") == ["unterminated"])
    }
}
