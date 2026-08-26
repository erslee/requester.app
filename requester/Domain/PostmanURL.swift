import Foundation

/// Turns Postman's URL representation into a plain URL plus query parameters.
///
/// It arrives either as a string or as an object with `raw`, `protocol`, `host`,
/// `path`, `port`, `query`, and `variable`. `raw` is authoritative when present;
/// the pieces are only assembled when it is missing.
nonisolated enum PostmanURL {
    struct Parsed {
        var url: String = ""
        var params: [KeyValueItem] = []
        var warnings: [String] = []
    }

    static func parse(_ value: Any?) -> Parsed {
        switch value {
        case let raw as String:
            return split(raw)
        case let object as [String: Any]:
            return parse(object)
        default:
            return Parsed()
        }
    }

    private static func parse(_ object: [String: Any]) -> Parsed {
        var result = Parsed()

        let base = (object["raw"] as? String) ?? assemble(object)
        result = split(base)

        // An explicit query list is authoritative over whatever was in `raw`.
        if let query = object["query"] as? [[String: Any]], !query.isEmpty {
            result.params = query.compactMap { item in
                guard let key = item["key"] as? String else { return nil }
                return KeyValueItem(
                    key: decoded(key),
                    value: decoded(PostmanImporter.stringValue(item["value"]) ?? ""),
                    enabled: (item["disabled"] as? Bool) != true,
                    description: PostmanImporter.stringValue(item["description"]) ?? ""
                )
            }
        }

        // Path variables (`:mapId`) have no equivalent, so their values are
        // substituted in -- which is what Postman would have sent. A variable
        // with no value is left visible rather than replaced with nothing.
        var substituted = 0
        for variable in (object["variable"] as? [[String: Any]]) ?? [] {
            guard let key = variable["key"] as? String,
                  let value = PostmanImporter.stringValue(variable["value"]),
                  !value.isEmpty
            else { continue }
            let placeholder = ":\(key)"
            guard result.url.contains(placeholder) else { continue }
            result.url = result.url.replacingOccurrences(of: placeholder, with: value)
            substituted += 1
        }
        if substituted == 1 {
            result.warnings.append("1 path variable replaced with its value.")
        } else if substituted > 1 {
            result.warnings.append("\(substituted) path variables replaced with their values.")
        }

        return result
    }

    /// Rebuilds the URL from its parts, for exports that omit `raw`.
    private static func assemble(_ object: [String: Any]) -> String {
        let scheme = (object["protocol"] as? String).map { "\($0)://" } ?? ""
        let host = joined(object["host"], separator: ".")
        let port = PostmanImporter.stringValue(object["port"]).map { ":\($0)" } ?? ""
        let path = joined(object["path"], separator: "/")
        let separator = path.isEmpty || path.hasPrefix("/") ? "" : "/"
        return "\(scheme)\(host)\(port)\(separator)\(path)"
    }

    /// `host` and `path` are arrays in a normal export but strings in some.
    private static func joined(_ value: Any?, separator: String) -> String {
        switch value {
        case let text as String:
            return text
        case let parts as [Any]:
            return parts.compactMap { part in
                if let text = part as? String { return text }
                // A path segment can be an object carrying its own value.
                if let object = part as? [String: Any] {
                    return PostmanImporter.stringValue(object["value"])
                }
                return PostmanImporter.stringValue(part)
            }
            .joined(separator: separator)
        default:
            return ""
        }
    }

    /// Separates any query string already in the URL into parameters.
    private static func split(_ url: String) -> Parsed {
        var result = Parsed()
        guard let separator = url.firstIndex(of: "?") else {
            result.url = url
            return result
        }

        result.url = String(url[url.startIndex..<separator])
        let query = url[url.index(after: separator)...]

        result.params = query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            guard let equals = pair.firstIndex(of: "=") else {
                return KeyValueItem(key: decoded(String(pair)))
            }
            return KeyValueItem(
                key: decoded(String(pair[pair.startIndex..<equals])),
                value: decoded(String(pair[pair.index(after: equals)...]))
            )
        }
        return result
    }

    /// Query values arrive percent-encoded, the way they appeared in the URL.
    /// They are decoded on the way in because the sender encodes them again --
    /// leaving them encoded sends `%7B` as `%257B`.
    private static func decoded(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }
}
