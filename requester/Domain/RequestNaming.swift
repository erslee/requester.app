import Foundation

/// Derives a readable label for a request that has not been explicitly named,
/// so the sidebar and editor never show a blank row. Once the user types a real
/// name and saves it, that takes over permanently.
nonisolated enum RequestNaming {
    static let fallback = "Untitled Request"

    static func displayName(for request: APIRequest) -> String {
        request.name.trimmingCharacters(in: .whitespaces).isEmpty
            ? derivedName(fromURL: request.url)
            : request.name
    }

    /// Host plus the last path segment, e.g. `swapi.info/planets`.
    ///
    /// Parsed by hand rather than with `URLComponents`, which rejects a URL that
    /// still contains `{{variables}}` -- curly braces are not legal in a host,
    /// so a templated URL would otherwise fall through to the fallback and every
    /// row would read "Untitled Request".
    static func derivedName(fromURL url: String) -> String {
        var rest = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return fallback }

        if let schemeEnd = rest.range(of: "://") {
            rest = String(rest[schemeEnd.upperBound...])
        }
        rest = String(rest.prefix { $0 != "?" && $0 != "#" })

        let segments = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let host = segments.first, !host.isEmpty else { return fallback }

        let lastSegment = segments.count > 1 ? segments[segments.count - 1] : ""
        return lastSegment.isEmpty ? host : "\(host)/\(lastSegment)"
    }
}
