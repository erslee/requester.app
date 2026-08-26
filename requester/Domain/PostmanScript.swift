import Foundation

/// Rewrites a Postman test script into the API our script runner provides.
///
/// Postman scripts are JavaScript against its `pm.*` object; ours run against a
/// `response` object and a `variables` object. The common calls -- reading the
/// response and writing a variable -- map directly, and those are what make a
/// collection's auth chaining work. Anything else is left as it was and flagged
/// for review, rather than being silently mangled.
nonisolated enum PostmanScript {
    /// `exec` is an array of lines in a normal export, a single string in some.
    static func source(from exec: Any?) -> String {
        switch exec {
        case let lines as [Any]:
            lines.compactMap { $0 as? String }.joined(separator: "\n")
        case let text as String:
            text
        default:
            ""
        }
    }

    private static let rewrites: [(pattern: String, template: String)] = [
        // Writing a variable, in all four of Postman's scopes.
        (
            #"pm\.(?:collectionVariables|environment|globals|variables)\.set\(\s*(['"])([^'"]+)\1\s*,\s*(.+?)\s*\)"#,
            #"variables["$2"] = $3"#
        ),
        // Reading one back.
        (
            #"pm\.(?:collectionVariables|environment|globals|variables)\.get\(\s*(['"])([^'"]+)\1\s*\)"#,
            #"variables["$2"]"#
        ),
        (#"pm\.response\.json\(\)"#, "response.json()"),
        (#"pm\.response\.text\(\)"#, "response.text"),
        (#"pm\.response\.code"#, "response.statusCode"),
        (#"pm\.response\.headers\.get\(\s*(['"])([^'"]+)\1\s*\)"#, #"response.headers["$2"]"#),
    ]

    static func translated(_ source: String) -> String {
        var result = source
        for rewrite in rewrites {
            guard let regex = try? NSRegularExpression(pattern: rewrite.pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: rewrite.template
            )
        }
        return result
    }

    /// True when calls remain that have no equivalent -- `pm.test`, `pm.expect`
    /// and the like -- so the import can say which scripts need a look.
    static func stillReferencesPostman(_ source: String) -> Bool {
        source.contains("pm.")
    }
}
