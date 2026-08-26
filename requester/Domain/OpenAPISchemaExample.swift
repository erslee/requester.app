import Foundation

/// Builds the example request body an operation's schema describes.
///
/// Walked as loose dictionaries for the same reason `PostmanImporter` is: the
/// schema vocabulary is broad and inconsistently used, and a strict decode
/// would reject a whole document over one unexpected keyword.
///
/// The result is a starting point, not a contract -- the point is that a newly
/// imported request has a body shaped like the one the endpoint wants, ready to
/// be edited.
nonisolated enum OpenAPISchemaExample {
    /// Nesting deeper than this yields `null` rather than recursing further.
    /// Guards inline nesting; `$ref` cycles are caught separately by the
    /// visited set, since a self-referential schema would otherwise recurse
    /// until the stack gives out.
    static let maximumDepth = 8

    struct Generated: Sendable {
        var text: String
        var warnings: [String] = []
    }

    /// The JSON text for a schema, or empty text if there is nothing to build.
    static func json(for schema: Any?, in document: [String: Any]) -> Generated {
        var warnings: [String] = []
        let value = value(
            for: schema, in: document, visited: [], depth: 0, warnings: &warnings
        )
        guard let value else { return Generated(text: "", warnings: warnings) }

        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        ) else {
            return Generated(text: "", warnings: warnings)
        }
        return Generated(text: String(decoding: data, as: UTF8.self), warnings: warnings)
    }

    // MARK: - Values

    private static func value(
        for schema: Any?,
        in document: [String: Any],
        visited: Set<String>,
        depth: Int,
        warnings: inout [String]
    ) -> Any? {
        guard var schema = schema as? [String: Any] else { return nil }
        var visited = visited

        if let reference = schema["$ref"] as? String {
            // A schema that contains itself is legal and common (a tree node,
            // a linked list). Stopping the second time round keeps the example
            // finite; the alternative is a stack overflow on a valid document.
            guard !visited.contains(reference) else {
                note("\(name(of: reference)) refers to itself; the example stops there.", &warnings)
                return NSNull()
            }
            guard let resolved = dereference(reference, in: document, warnings: &warnings) else {
                return NSNull()
            }
            visited.insert(reference)
            schema = resolved
        }

        schema = flattened(schema, in: document, visited: visited, warnings: &warnings)

        // What the document says explicitly always wins over anything invented.
        if let example = schema["example"] { return example }
        if let example = (schema["examples"] as? [Any])?.first { return example }
        if let fallback = schema["default"] { return fallback }
        if let choice = (schema["enum"] as? [Any])?.first { return choice }

        guard depth < maximumDepth else { return NSNull() }

        switch type(of: schema) {
        case "object":
            return object(from: schema, in: document, visited: visited, depth: depth, warnings: &warnings)

        case "array":
            let element = value(
                for: schema["items"], in: document, visited: visited,
                depth: depth + 1, warnings: &warnings
            )
            return element.map { [$0] } ?? []

        case "integer": return 0
        case "number": return 0
        case "boolean": return false
        case "null": return NSNull()
        case "string": return string(for: schema["format"] as? String)
        default: return NSNull()
        }
    }

    private static func object(
        from schema: [String: Any],
        in document: [String: Any],
        visited: Set<String>,
        depth: Int,
        warnings: inout [String]
    ) -> Any {
        guard let properties = schema["properties"] as? [String: Any] else { return [String: Any]() }

        var result: [String: Any] = [:]
        for (key, property) in properties {
            // `readOnly` marks a field the server sends back but will not accept.
            // Only request bodies are generated here, so those are left out.
            if (property as? [String: Any])?["readOnly"] as? Bool == true { continue }

            result[key] = value(
                for: property, in: document, visited: visited,
                depth: depth + 1, warnings: &warnings
            ) ?? NSNull()
        }
        return result
    }

    /// A schema's effective type, inferred when the document leaves it out --
    /// which is legal, and common in hand-written specs.
    private static func type(of schema: [String: Any]) -> String {
        if let declared = schema["type"] as? String { return declared }
        // OpenAPI 3.1 allows a type union, e.g. ["string", "null"]. The first
        // non-null entry is the one worth showing.
        if let union = schema["type"] as? [String] {
            return union.first { $0 != "null" } ?? "null"
        }
        if schema["properties"] != nil { return "object" }
        if schema["items"] != nil { return "array" }
        return ""
    }

    /// A placeholder that looks like the format asks for, so a date field
    /// arrives as something a server might actually parse.
    private static func string(for format: String?) -> String {
        switch format {
        case "date-time": "2026-01-01T00:00:00Z"
        case "date": "2026-01-01"
        case "time": "00:00:00"
        case "uuid": "00000000-0000-0000-0000-000000000000"
        case "email": "user@example.com"
        case "uri", "url": "https://example.com"
        case "hostname": "example.com"
        case "ipv4": "127.0.0.1"
        case "password": "password"
        default: "string"
        }
    }

    // MARK: - Composition

    /// Folds `allOf` into one schema, and picks the first branch of `oneOf` /
    /// `anyOf`.
    ///
    /// A body has to be one concrete shape, and there is no way to know which
    /// branch is wanted -- so the first is used and the choice is reported,
    /// rather than the field being dropped as if the spec never mentioned it.
    private static func flattened(
        _ schema: [String: Any],
        in document: [String: Any],
        visited: Set<String>,
        warnings: inout [String]
    ) -> [String: Any] {
        var schema = schema

        if let branches = (schema["oneOf"] ?? schema["anyOf"]) as? [Any], !branches.isEmpty {
            if branches.count > 1 {
                note("A field allows \(branches.count) alternative shapes; the first was used.", &warnings)
            }
            schema.removeValue(forKey: "oneOf")
            schema.removeValue(forKey: "anyOf")
            if let first = resolved(branches[0], in: document, warnings: &warnings) {
                schema.merge(first) { existing, _ in existing }
            }
        }

        guard let parts = schema["allOf"] as? [Any] else { return schema }
        schema.removeValue(forKey: "allOf")

        var properties = (schema["properties"] as? [String: Any]) ?? [:]
        for part in parts {
            guard let part = resolved(part, in: document, warnings: &warnings) else { continue }
            let merged = flattened(part, in: document, visited: visited, warnings: &warnings)
            for (key, value) in merged where key != "properties" {
                if schema[key] == nil { schema[key] = value }
            }
            for (key, value) in (merged["properties"] as? [String: Any]) ?? [:] {
                properties[key] = value
            }
        }
        if !properties.isEmpty {
            schema["properties"] = properties
            if schema["type"] == nil { schema["type"] = "object" }
        }
        return schema
    }

    /// One level of `$ref` resolution, for composition keywords.
    private static func resolved(
        _ schema: Any?, in document: [String: Any], warnings: inout [String]
    ) -> [String: Any]? {
        guard let schema = schema as? [String: Any] else { return nil }
        guard let reference = schema["$ref"] as? String else { return schema }
        return dereference(reference, in: document, warnings: &warnings)
    }

    // MARK: - References

    /// Resolves a local JSON pointer -- `#/components/schemas/Foo` in OpenAPI 3,
    /// `#/definitions/Foo` in Swagger 2 -- against the document.
    ///
    /// A reference into another file or over the network is not followed. This
    /// app has no business fetching whatever a spec points at, so those are
    /// reported and the field falls back to `null`.
    static func dereference(
        _ reference: String, in document: [String: Any], warnings: inout [String]
    ) -> [String: Any]? {
        guard reference.hasPrefix("#/") else {
            note("“\(reference)” points outside this document and was not followed.", &warnings)
            return nil
        }

        var node: Any = document
        for component in reference.dropFirst(2).split(separator: "/") {
            // JSON Pointer escaping: ~1 is "/" and ~0 is "~", in that order.
            let key = component
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            guard let object = node as? [String: Any], let next = object[key] else {
                note("“\(reference)” is not in this document.", &warnings)
                return nil
            }
            node = next
        }
        return node as? [String: Any]
    }

    private static func name(of reference: String) -> String {
        reference.split(separator: "/").last.map(String.init) ?? reference
    }

    /// Warnings are shown as a list, and the same schema reached twice would
    /// otherwise report the same line twice.
    private static func note(_ warning: String, _ warnings: inout [String]) {
        guard !warnings.contains(warning) else { return }
        warnings.append(warning)
    }
}
