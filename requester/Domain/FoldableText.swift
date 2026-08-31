import Foundation

/// A body formatted for reading, split into lines, with the bracket pairs that
/// can be collapsed.
///
/// Everything a viewer needs comes out of one pass over the bytes: the
/// formatted text, where each line starts, and which line closes each block.
/// Indexing the text afterwards would mean walking megabytes a second and third
/// time, which is exactly what makes a large response feel slow.
///
/// Offsets are recorded twice because two different consumers need them. Byte
/// offsets address `bytes` when a projection is assembled; UTF-16 offsets are
/// what TextKit counts in, so they are what maps a position on screen back to
/// a line number. For plain ASCII the two agree, but a response with accented
/// text -- or the fold marker itself -- would put the gutter out of step.
nonisolated struct FoldableText: Sendable {
    /// Distinguishes one body from the next. Two projections of the *same*
    /// document differ by a fold and can be applied as an edit; projections of
    /// different documents cannot.
    let id = UUID()

    /// The formatted text, UTF-8, lines separated by a single newline.
    let bytes: [UInt8]

    /// Byte offset at which each line begins.
    let lineStarts: [Int]

    /// UTF-16 offset at which each line begins.
    let utf16LineStarts: [Int]

    /// For a line that opens a collapsible block, the line carrying the
    /// matching closing bracket; `-1` for every other line.
    private let closers: [Int]

    /// Total UTF-16 length, standing in as the sentinel past the last line.
    private let utf16Count: Int

    var lineCount: Int { lineStarts.count }

    var text: String { String(decoding: bytes, as: UTF8.self) }

    /// The line holding the closing bracket for a block opened on `line`, or
    /// nil when nothing collapsible starts there.
    ///
    /// An empty `{}` or `[]` never reports one: the formatter keeps those on a
    /// single line, so there is nothing to hide.
    func closingLine(for line: Int) -> Int? {
        let closer = closers[line]
        return closer > line ? closer : nil
    }

    private func byteRange(of line: Int) -> Range<Int> {
        lineStarts[line]..<(line + 1 < lineStarts.count ? lineStarts[line + 1] : bytes.count)
    }

    private func utf16Length(of line: Int) -> Int {
        (line + 1 < utf16LineStarts.count ? utf16LineStarts[line + 1] : utf16Count)
            - utf16LineStarts[line]
    }

    // MARK: - Building

    /// Formats JSON and pairs its brackets in one pass.
    ///
    /// Deliberately not `JSONSerialization`, for the reason `JSONFormatter`
    /// gives: a truncated body still has to come out readable. Brackets left
    /// unclosed at the end simply never gain a fold point.
    static func json(_ source: String) -> FoldableText {
        var builder = Builder(capacity: source.utf8.count * 2)
        var openers: [Int] = []
        var depth = 0
        var isInString = false
        var isEscaped = false

        /// An opening bracket does not know yet whether it is empty, so the
        /// newline after it waits for the next meaningful character.
        var isAwaitingFirstMember = false

        for byte in source.utf8 {
            if isInString {
                builder.emit(byte)
                if isEscaped {
                    isEscaped = false
                } else if byte == .backslash {
                    isEscaped = true
                } else if byte == .quote {
                    isInString = false
                }
                continue
            }

            // The input's own whitespace is dropped; this pass owns layout.
            if byte.isJSONWhitespace { continue }

            if isAwaitingFirstMember {
                isAwaitingFirstMember = false
                if byte == .closeBrace || byte == .closeBracket {
                    // Nothing inside: keep it on one line, and drop the opener
                    // that was waiting for a block worth collapsing.
                    depth -= 1
                    builder.emit(byte)
                    _ = openers.popLast()
                    continue
                }
                builder.breakLine(indentedTo: depth)
            }

            switch byte {
            case .openBrace, .openBracket:
                builder.emit(byte)
                depth += 1
                isAwaitingFirstMember = true
                openers.append(builder.lineCount - 1)
            case .closeBrace, .closeBracket:
                depth -= 1
                builder.breakLine(indentedTo: depth)
                builder.emit(byte)
                if let opener = openers.popLast() {
                    builder.closers[opener] = builder.lineCount - 1
                }
            case .comma:
                builder.emit(byte)
                builder.breakLine(indentedTo: depth)
            case .colon:
                builder.emit(byte)
                builder.emit(.space)
            case .quote:
                isInString = true
                builder.emit(byte)
            default:
                builder.emit(byte)
            }
        }

        return builder.finish()
    }

    /// Indexes text that is shown as it arrived -- a non-JSON body, or the raw
    /// view of one. There is nothing to collapse, but the lines still number.
    static func plain(_ source: String) -> FoldableText {
        var builder = Builder(capacity: source.utf8.count)
        for byte in source.utf8 {
            if byte == .newline {
                builder.breakLine(indentedTo: 0)
            } else {
                builder.emit(byte)
            }
        }
        return builder.finish()
    }

    /// Accumulates the text and the three indices together, so a byte is
    /// examined once and the offsets can never drift apart from it.
    private struct Builder {
        var bytes: [UInt8] = []
        var lineStarts: [Int] = [0]
        var utf16LineStarts: [Int] = [0]
        var closers: [Int] = [-1]
        private var utf16Count = 0

        var lineCount: Int { lineStarts.count }

        init(capacity: Int) {
            bytes.reserveCapacity(capacity)
        }

        mutating func emit(_ byte: UInt8) {
            bytes.append(byte)
            // A continuation byte carries no UTF-16 unit of its own, and the
            // lead of a four-byte sequence carries two -- it becomes a
            // surrogate pair.
            if byte & 0xC0 != 0x80 { utf16Count += 1 }
            if byte & 0xF8 == 0xF0 { utf16Count += 1 }
        }

        mutating func breakLine(indentedTo depth: Int) {
            emit(.newline)
            lineStarts.append(bytes.count)
            utf16LineStarts.append(utf16Count)
            closers.append(-1)
            for _ in 0..<max(depth, 0) {
                emit(.space)
                emit(.space)
            }
        }

        func finish() -> FoldableText {
            FoldableText(
                bytes: bytes,
                lineStarts: lineStarts,
                utf16LineStarts: utf16LineStarts,
                closers: closers,
                utf16Count: utf16Count
            )
        }
    }

    // MARK: - Projection

    /// What the text view actually holds: the text with `folded` blocks
    /// collapsed onto their opening line, and the indices needed to read a
    /// position on screen back to a line of the original.
    struct Projection: Sendable {
        let text: String

        /// UTF-16 offset at which each displayed line begins.
        let lineStarts: [Int]

        /// The line of the unfolded text that each displayed line came from.
        let sourceLines: [Int]

        /// UTF-16 length of the longest displayed line, excluding its newline.
        ///
        /// With a monospaced font this gives the width of the document without
        /// laying any of it out -- and a text view whose width is known up
        /// front is the difference between TextKit measuring a screenful and
        /// measuring every line in the response.
        let longestLineLength: Int

        var lineCount: Int { lineStarts.count }

        /// UTF-16 range of a displayed line, including its newline.
        private func lineRange(_ line: Int) -> NSRange {
            let start = lineStarts[line]
            let end = line + 1 < lineStarts.count
                ? lineStarts[line + 1] : (text as NSString).length
            return NSRange(location: start, length: end - start)
        }

        func lineText(_ line: Int) -> String {
            (text as NSString).substring(with: lineRange(line))
        }

        /// The one span in which this projection differs from `previous`, as a
        /// range in the previous text and what to put there.
        ///
        /// Collapsing a block changes a single contiguous region. Applying just
        /// that leaves the reader's scroll position and selection alone, which
        /// handing the text view a whole new string does not: TextKit lays a
        /// fresh document out lazily, so there is briefly no geometry to scroll
        /// back to and the view snaps to the top.
        ///
        /// Lines are matched on the source line they show, which is one integer
        /// compare each. Only the two boundary lines are compared as text --
        /// a collapsed opener keeps its source line but gains the marker, so
        /// the edit really begins one line earlier than the maps suggest.
        func difference(from previous: Projection) -> (range: NSRange, replacement: String)? {
            let shared = min(previous.lineCount, lineCount)

            var first = 0
            while first < shared, previous.sourceLines[first] == sourceLines[first] {
                first += 1
            }
            if first > 0, previous.lineText(first - 1) != lineText(first - 1) {
                first -= 1
            }

            var tail = 0
            while tail < shared - first,
                  previous.sourceLines[previous.lineCount - 1 - tail]
                      == sourceLines[lineCount - 1 - tail] {
                tail += 1
            }
            if tail > 0,
               previous.lineText(previous.lineCount - tail) != lineText(lineCount - tail) {
                tail -= 1
            }

            let oldEndLine = previous.lineCount - tail
            let newEndLine = lineCount - tail
            guard first < oldEndLine || first < newEndLine else { return nil }

            let oldText = previous.text as NSString
            let newText = text as NSString
            let oldStart = previous.lineStarts[first]
            let oldEnd = oldEndLine < previous.lineCount
                ? previous.lineStarts[oldEndLine] : oldText.length
            let newStart = lineStarts[first]
            let newEnd = newEndLine < lineCount ? lineStarts[newEndLine] : newText.length

            return (
                NSRange(location: oldStart, length: oldEnd - oldStart),
                newText.substring(with: NSRange(location: newStart, length: newEnd - newStart))
            )
        }

        /// The displayed line containing a UTF-16 offset -- what the gutter
        /// asks once per line on screen, so it is a binary search rather than
        /// a walk.
        func displayedLine(containing utf16Offset: Int) -> Int {
            var low = 0
            var high = lineStarts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if lineStarts[middle] <= utf16Offset { low = middle } else { high = middle - 1 }
            }
            return low
        }
    }

    /// Shown between an opener and its closer in place of a collapsed block.
    static let foldMarker = " ⋯ "

    /// Collapses `folded` and reports what is left.
    ///
    /// A collapsed block keeps its opening line, gains the marker, and is
    /// rejoined to its closing bracket -- `"tags": [ ⋯ ],` -- so the line still
    /// reads as the thing it stands for. Lines a fold swallows are simply not
    /// emitted, which is why `sourceLines` is needed to number them.
    func projected(folding folded: Set<Int>) -> Projection {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var lineStarts = [0]
        var sourceLines: [Int] = []
        var utf16Count = 0
        var longestLineLength = 0

        let marker = Array(Self.foldMarker.utf8)
        let markerUTF16 = Self.foldMarker.utf16.count

        var line = 0
        while line < lineCount {
            sourceLines.append(line)

            guard let closer = closingLine(for: line), folded.contains(line) else {
                out.append(contentsOf: bytes[byteRange(of: line)])
                let length = utf16Length(of: line)
                longestLineLength = max(longestLineLength, length - 1)
                utf16Count += length
                line += 1
                if line < lineCount {
                    lineStarts.append(utf16Count)
                }
                continue
            }

            // The opener without its newline, the marker, then the closing
            // bracket with the indentation it no longer needs.
            var opening = byteRange(of: line)
            var openingUTF16 = utf16Length(of: line)
            if bytes[opening.upperBound - 1] == .newline {
                opening = opening.lowerBound..<(opening.upperBound - 1)
                openingUTF16 -= 1
            }
            out.append(contentsOf: bytes[opening])

            out.append(contentsOf: marker)

            var closing = byteRange(of: closer)
            var closingUTF16 = utf16Length(of: closer)
            while closing.lowerBound < closing.upperBound, bytes[closing.lowerBound] == .space {
                closing = (closing.lowerBound + 1)..<closing.upperBound
                closingUTF16 -= 1
            }
            out.append(contentsOf: bytes[closing])

            let length = openingUTF16 + markerUTF16 + closingUTF16
            longestLineLength = max(longestLineLength, length - 1)
            utf16Count += length

            // The last line of the document carries no newline of its own.
            if out.last != .newline {
                out.append(.newline)
                utf16Count += 1
            }

            line = closer + 1
            if line < lineCount {
                lineStarts.append(utf16Count)
            }
        }

        return Projection(
            text: String(decoding: out, as: UTF8.self),
            lineStarts: lineStarts,
            sourceLines: sourceLines,
            longestLineLength: max(longestLineLength, 0)
        )
    }
}

/// The bytes the JSON pass switches on, named so the pass itself reads as
/// grammar rather than as hex.
nonisolated private extension UInt8 {
    static let newline: UInt8 = 0x0A
    static let space: UInt8 = 0x20
    static let quote: UInt8 = 0x22
    static let comma: UInt8 = 0x2C
    static let colon: UInt8 = 0x3A
    static let backslash: UInt8 = 0x5C
    static let openBracket: UInt8 = 0x5B
    static let closeBracket: UInt8 = 0x5D
    static let openBrace: UInt8 = 0x7B
    static let closeBrace: UInt8 = 0x7D

    var isJSONWhitespace: Bool {
        self == .space || self == 0x09 || self == .newline || self == 0x0D
    }
}
