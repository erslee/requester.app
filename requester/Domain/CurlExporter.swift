import Foundation

/// Renders a request as a `curl` command, the inverse of `CurlParser`.
///
/// Deliberately built from the very `URLRequest` the executor would send,
/// rather than walking `APIRequest` a second time: params folded into the URL,
/// auth expanded into a header, the body encoded for its mode -- all of that
/// already has exactly one implementation, and duplicating it here is how an
/// exported command would come to describe something Send does not do.
///
/// Everything is single-quoted. It is the one shell quoting style with no
/// escape table at all -- inside `'…'` every character is literal -- so a body
/// full of double quotes, backslashes and newlines needs no encoding decisions.
nonisolated enum CurlExporter {
    /// Continuation lines are indented, so a long command stays readable when
    /// it is pasted somewhere that does not re-wrap it.
    static let indent = "  "

    /// The command for a request as it will be sent.
    ///
    /// Callers are expected to have merged the project's global headers and
    /// resolved `{{variables}}` first -- an exported command is one you paste
    /// into a terminal, so it carries values, not templates.
    static func command(for request: APIRequest) throws -> String {
        command(for: try HTTPExecutor.buildURLRequest(from: request))
    }

    static func command(for urlRequest: URLRequest) -> String {
        var lines = [
            "curl -X \(urlRequest.httpMethod ?? "GET") "
                + singleQuoted(urlRequest.url?.absoluteString ?? "")
        ]

        // Sorted, because `allHTTPHeaderFields` is a dictionary: without an
        // order of our own the same request would export differently each time.
        for (name, value) in (urlRequest.allHTTPHeaderFields ?? [:])
            .sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
            lines.append("-H " + singleQuoted("\(name): \(value)"))
        }

        // `--data-raw` rather than `-d`: `-d` reads a leading `@` as a filename,
        // which would turn a body that happens to start with one into a file
        // read. The flag also implies POST, so the explicit `-X` above stands.
        if let body = urlRequest.httpBody, !body.isEmpty {
            lines.append("--data-raw " + singleQuoted(String(decoding: body, as: UTF8.self)))
        }

        return lines.joined(separator: " \\\n" + indent)
    }

    /// A single quote cannot be escaped inside single quotes, so the only way
    /// to carry one is to close the string, splice in an escaped quote, and
    /// open a new one -- the familiar `'\''`. The shell joins the three pieces
    /// back into one argument.
    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
