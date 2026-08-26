import Foundation

/// Parses a pasted `curl` command into request fields.
///
/// Hand-rolled tokenizer plus a flag-by-flag state machine, rather than a
/// dependency: the flags that matter here (multipart `-F`, basic auth `-u`,
/// cookies `-b`, line continuations) are not covered by an off-the-shelf
/// parser. Unrecognized flags land in `unsupported` and are surfaced to the
/// user rather than silently dropped.
nonisolated struct CurlParser: Sendable {
    struct Parsed: Sendable, Equatable {
        var method: HTTPMethod = .get
        var url: String = ""
        var params: [KeyValueItem] = []
        var headers: [KeyValueItem] = []
        var bodyMode: BodyMode = .none
        var rawBody: String = ""
        var graphQLBody: GraphQLBody?
        var formFields: [FormField] = []
        var auth = AuthConfig()
        var unsupported: [String] = []
    }

    private static let dataFlags: Set<String> = [
        "-d", "--data", "--data-raw", "--data-binary", "--data-ascii", "--data-urlencode",
    ]
    private static let methodFlags: Set<String> = ["-X", "--request"]
    private static let urlFlags: Set<String> = ["--url"]
    private static let headerFlags: Set<String> = ["-H", "--header"]
    private static let formFlags: Set<String> = ["-F", "--form"]
    private static let userFlags: Set<String> = ["-u", "--user"]
    private static let cookieFlags: Set<String> = ["-b", "--cookie"]
    private static let userAgentFlags: Set<String> = ["-A", "--user-agent"]
    private static let valuelessFlags: Set<String> = [
        "-k", "--insecure", "-L", "--location", "-s", "--silent", "-v", "--verbose",
        "-i", "--include", "-#", "--progress-bar", "-g", "--globoff", "--fail", "-f",
    ]

    /// Flags whose semantics are not modelled but which *do* consume a value.
    /// Without this list an unknown flag's value gets mistaken for the URL --
    /// the next bare token. Not exhaustive; anything else falls back to the
    /// conservative "unknown flag, do not consume a value" branch below.
    private static let unmodelledValueFlags: Set<String> = [
        "--retry", "--retry-delay", "--retry-max-time", "--connect-timeout", "--max-time",
        "-m", "--limit-rate", "-w", "--write-out", "--cacert", "--cert", "-E", "--key",
        "--resolve", "--interface", "-e", "--referer", "-x", "--proxy", "--range", "-r",
        "-o", "--output", "--proto",
    ]

    static func parse(_ raw: String) -> Parsed {
        var tokens = ShellTokenizer.tokenize(collapsingContinuations(in: raw))
        if let first = tokens.first, first == "$" || first == ">" { tokens.removeFirst() }
        if tokens.first?.lowercased() == "curl" { tokens.removeFirst() }

        var methodOverride: String?
        var url: String?
        var headers: [KeyValueItem] = []
        var dataParts: [String] = []
        var formFields: [FormField] = []
        var auth = AuthConfig()
        var unsupported: [String] = []
        var sawData = false
        var sawForm = false
        var sawCompressed = false

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let (flag, inlineValue) = splitInlineValue(token)

            func takeValue() -> String? {
                if let inlineValue { return inlineValue }
                guard index + 1 < tokens.count else { return nil }
                index += 1
                return tokens[index]
            }

            if methodFlags.contains(flag) {
                methodOverride = takeValue()?.uppercased()
            } else if urlFlags.contains(flag) {
                if let value = takeValue() { url = value }
            } else if headerFlags.contains(flag) {
                if let value = takeValue() {
                    let (key, headerValue) = partition(value, separator: ":")
                    headers.append(
                        KeyValueItem(
                            key: key.trimmingCharacters(in: .whitespaces),
                            value: headerValue.trimmingCharacters(in: .whitespaces)
                        )
                    )
                }
            } else if dataFlags.contains(flag) {
                if let value = takeValue() {
                    dataParts.append(value)
                    sawData = true
                }
            } else if formFlags.contains(flag) {
                if let value = takeValue() {
                    formFields.append(parseFormField(value))
                    sawForm = true
                }
            } else if userFlags.contains(flag) {
                if let value = takeValue() {
                    let (username, password) = partition(value, separator: ":")
                    auth.type = .basic
                    auth.basicUsername = username
                    auth.basicPassword = password
                }
            } else if cookieFlags.contains(flag) {
                if let value = takeValue() {
                    headers.append(KeyValueItem(key: "Cookie", value: value))
                }
            } else if userAgentFlags.contains(flag) {
                if let value = takeValue() {
                    headers.append(KeyValueItem(key: "User-Agent", value: value))
                }
            } else if flag == "--compressed" {
                sawCompressed = true
            } else if valuelessFlags.contains(flag) {
                // Nothing to record: these do not affect the request we build.
            } else if !flag.hasPrefix("-") {
                if url == nil { url = token } else { unsupported.append(token) }
            } else if unmodelledValueFlags.contains(flag) {
                let value = takeValue()
                unsupported.append(value.map { "\(flag) \($0)" } ?? flag)
            } else {
                unsupported.append(token)
            }

            index += 1
        }

        var parsed = Parsed()

        if sawForm {
            parsed.bodyMode = .form
        } else if sawData {
            parsed.bodyMode = .raw
            // A JSON payload split across several -d flags must be concatenated;
            // form-style pairs are joined with & the way curl itself does.
            parsed.rawBody = dataParts.contains(where: {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
            })
                ? dataParts.joined()
                : dataParts.joined(separator: "&")
        }

        // A JSON payload with a `query` in it is a GraphQL request. Recognising
        // it puts the query and variables in the GraphQL tab, where they can be
        // read and edited, instead of leaving one long escaped line in Raw.
        if parsed.bodyMode == .raw,
           let graphQL = GraphQLDetection.body(fromJSON: parsed.rawBody) {
            parsed.bodyMode = .graphQL
            parsed.graphQLBody = graphQL
            parsed.rawBody = ""
        }

        parsed.method = (sawData || sawForm) ? .post : .get
        if let methodOverride {
            if let method = HTTPMethod(rawValue: methodOverride) {
                parsed.method = method
            } else {
                unsupported.append("-X \(methodOverride) (unrecognized method)")
            }
        }

        if sawCompressed, !headers.contains(where: { $0.key.lowercased() == "accept-encoding" }) {
            headers.append(KeyValueItem(key: "Accept-Encoding", value: "gzip, deflate, br"))
        }

        parsed.headers = mergingDuplicateCookieHeaders(headers)
        parsed.formFields = formFields
        parsed.auth = auth

        if let url {
            let (base, params) = splitURLAndParams(url)
            parsed.url = base
            parsed.params = params
        } else {
            unsupported.append("(no URL found in command)")
        }
        parsed.unsupported = unsupported

        return parsed
    }

    /// True for text that should be treated as a curl command rather than a URL.
    static func looksLikeCurlCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "curl" || trimmed.hasPrefix("curl ") || trimmed.hasPrefix("curl\n")
            || trimmed.hasPrefix("$ curl ") || trimmed.hasPrefix("curl\t")
    }

    // MARK: - Tokenizing

    /// Collapses a trailing backslash + newline into a single logical line.
    private static func collapsingContinuations(in raw: String) -> String {
        raw.replacing(/\\\r?\n/, with: " ")
    }

    // MARK: - Pieces

    /// Supports `--flag=value` alongside `--flag value`.
    private static func splitInlineValue(_ token: String) -> (flag: String, value: String?) {
        guard token.hasPrefix("--"), token.contains("=") else { return (token, nil) }
        let (flag, value) = partition(token, separator: "=")
        return (flag, value)
    }

    private static func partition(
        _ text: String, separator: Character
    ) -> (before: String, after: String) {
        guard let index = text.firstIndex(of: separator) else { return (text, "") }
        return (String(text[text.startIndex..<index]), String(text[text.index(after: index)...]))
    }

    private static func parseFormField(_ raw: String) -> FormField {
        let (key, rest) = partition(raw, separator: "=")
        guard rest.hasPrefix("@") else { return FormField(key: key, value: rest) }

        let parts = rest.dropFirst().split(separator: ";", omittingEmptySubsequences: false)
        let path = parts.first.map(String.init) ?? ""
        let contentType = parts.dropFirst()
            .first { $0.hasPrefix("type=") }
            .map { String($0.dropFirst("type=".count)) }
        return FormField(key: key, isFile: true, filePath: path, contentType: contentType)
    }

    /// curl sends repeated `-b`/`Cookie:` values as one joined header.
    private static func mergingDuplicateCookieHeaders(
        _ headers: [KeyValueItem]
    ) -> [KeyValueItem] {
        let cookieValues = headers.filter { $0.key.lowercased() == "cookie" }.map(\.value)
        guard cookieValues.count > 1 else { return headers }
        return headers.filter { $0.key.lowercased() != "cookie" }
            + [KeyValueItem(key: "Cookie", value: cookieValues.joined(separator: "; "))]
    }

    private static func splitURLAndParams(_ url: String) -> (String, [KeyValueItem]) {
        guard var components = URLComponents(string: url) else { return (url, []) }
        let params = (components.queryItems ?? []).map {
            KeyValueItem(key: $0.name, value: $0.value ?? "")
        }
        components.query = nil
        return (components.string ?? url, params)
    }
}
