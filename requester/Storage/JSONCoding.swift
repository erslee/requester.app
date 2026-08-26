import Foundation

/// Shared coders for everything persisted. Dates are ISO 8601 with fractional
/// seconds; decoding also accepts the whole-second form so a file hand-edited
/// to `2026-07-18T13:22:39Z` still loads.
nonisolated enum JSONCoding {
    private static let fractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSeconds = Date.ISO8601FormatStyle()

    static let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            try fractionalSeconds.format(date).encode(to: encoder)
        }
        return encoder
    }()

    /// For JSONL records, which must stay on a single line.
    static let compactEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            try fractionalSeconds.format(date).encode(to: encoder)
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { container in
            let text = try container.singleValueContainer().decode(String.self)
            if let date = try? fractionalSeconds.parse(text) { return date }
            if let date = try? wholeSeconds.parse(text) { return date }
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "Not an ISO 8601 date: \(text)"
                )
            )
        }
        return decoder
    }()
}
