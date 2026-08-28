import Foundation

/// Reads a Postman v2/v2.1 collection export.
///
/// Parsed as loose dictionaries rather than `Decodable` types: the schema is
/// permissive in ways that matter -- `url` is either a string or an object,
/// `host` and `path` are either arrays or strings, and `body` changes shape per
/// mode -- so tolerant walking survives real exports that strict decoding would
/// reject wholesale.
///
/// Anything that cannot be represented is reported in `warnings` rather than
/// dropped silently, so the import says what did not come across.
nonisolated enum PostmanImporter {
    struct Collection: Sendable {
        var name: String
        /// Folders the collection declares that no request landed in -- an
        /// empty folder is still part of the shape the user exported.
        var folders: [[String]] = []
        /// Collection variables, which use the same `{{name}}` syntax as ours.
        var variables: [String: String]
        /// `id` and `projectID` are left empty for the caller to assign.
        var requests: [APIRequest]
        var warnings: [String]
        var scriptsNeedingReview: [String]
    }

    static func collection(from data: Data) throws -> Collection {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PostmanImportError.notJSON
        }
        guard let info = root["info"] as? [String: Any], root["item"] is [Any] else {
            throw PostmanImportError.notACollection
        }

        var result = Collection(
            name: (info["name"] as? String) ?? "Imported Collection",
            variables: [:],
            requests: [],
            warnings: [],
            scriptsNeedingReview: []
        )

        for variable in (root["variable"] as? [[String: Any]]) ?? [] {
            guard let key = variable["key"] as? String else { continue }
            result.variables[key] = stringValue(variable["value"]) ?? ""
        }

        // Collection-level pre-request and test scripts have no equivalent: our
        // scripts belong to a single request.
        for event in (root["event"] as? [[String: Any]]) ?? [] {
            if let listen = event["listen"] as? String {
                result.warnings.append("Collection-level “\(listen)” script was not imported.")
            }
        }

        append(items: (root["item"] as? [Any]) ?? [], folder: [], to: &result)

        if result.requests.isEmpty {
            throw PostmanImportError.noRequests
        }
        return result
    }

    // MARK: - Items

    /// Walks the item tree, keeping its shape: a Postman folder becomes a
    /// folder here, and a request keeps its own short name rather than one with
    /// the whole path glued on the front.
    private static func append(items: [Any], folder: [String], to result: inout Collection) {
        for case let item as [String: Any] in items {
            let name = (item["name"] as? String) ?? "Untitled"

            if let children = item["item"] as? [Any] {
                // An empty Postman folder still becomes a folder here, so the
                // imported collection looks like the one that was exported.
                if children.isEmpty { result.folders.append(folder + [name]) }
                append(items: children, folder: folder + [name], to: &result)
                continue
            }
            guard let request = item["request"] else { continue }

            var imported = APIRequest(id: "", projectID: "", order: result.requests.count)
            imported.name = name
            imported.folder = folder
            apply(request: request, to: &imported, result: &result)
            applyScripts(from: item, to: &imported, result: &result)
            result.requests.append(imported)
        }
    }

    private static func apply(
        request: Any, to imported: inout APIRequest, result: inout Collection
    ) {
        // A request can be just a URL string.
        guard let request = request as? [String: Any] else {
            if let raw = request as? String {
                let parsed = PostmanURL.parse(raw)
                imported.url = parsed.url
                imported.params = parsed.params
            }
            return
        }

        if let method = request["method"] as? String,
           let known = HTTPMethod(rawValue: method.uppercased()) {
            imported.method = known
        }

        let parsed = PostmanURL.parse(request["url"])
        imported.url = parsed.url
        imported.params = parsed.params
        result.warnings.append(contentsOf: parsed.warnings.map { "\(imported.name): \($0)" })

        imported.headers = ((request["header"] as? [[String: Any]]) ?? []).compactMap { header in
            guard let key = header["key"] as? String, !key.isEmpty else { return nil }
            return KeyValueItem(
                key: key,
                value: stringValue(header["value"]) ?? "",
                enabled: (header["disabled"] as? Bool) != true,
                description: stringValue(header["description"]) ?? ""
            )
        }

        applyAuth(request["auth"], to: &imported, name: imported.name, result: &result)
        applyBody(request["body"], to: &imported, name: imported.name, result: &result)
    }

    // MARK: - Auth

    private static func applyAuth(
        _ auth: Any?, to imported: inout APIRequest, name: String, result: inout Collection
    ) {
        guard let auth = auth as? [String: Any], let type = auth["type"] as? String else { return }

        /// Postman stores each scheme's fields as an array of key/value pairs.
        func field(_ scheme: String, _ key: String) -> String {
            guard let entries = auth[scheme] as? [[String: Any]] else { return "" }
            return entries.first { $0["key"] as? String == key }
                .flatMap { stringValue($0["value"]) } ?? ""
        }

        switch type {
        case "noauth":
            imported.auth.type = .none
        case "bearer":
            imported.auth.type = .bearer
            imported.auth.bearerToken = field("bearer", "token")
        case "basic":
            imported.auth.type = .basic
            imported.auth.basicUsername = field("basic", "username")
            imported.auth.basicPassword = field("basic", "password")
        case "apikey":
            imported.auth.type = .apiKey
            imported.auth.apiKeyName = field("apikey", "key")
            imported.auth.apiKeyValue = field("apikey", "value")
            imported.auth.apiKeyIn = field("apikey", "in") == "query" ? .query : .header
        case "inherit":
            break
        default:
            result.warnings.append("\(name): “\(type)” auth is not supported and was skipped.")
        }
    }

    // MARK: - Body

    private static func applyBody(
        _ body: Any?, to imported: inout APIRequest, name: String, result: inout Collection
    ) {
        guard let body = body as? [String: Any], let mode = body["mode"] as? String else { return }

        switch mode {
        case "raw":
            let raw = stringValue(body["raw"]) ?? ""
            // A JSON payload carrying a `query` is really a GraphQL request.
            if let graphQL = GraphQLDetection.body(fromJSON: raw) {
                imported.bodyMode = .graphQL
                imported.graphQLBody = graphQL
            } else {
                imported.bodyMode = .raw
                imported.rawBody = raw
                imported.rawBodyType = rawBodyType(from: body)
            }

        case "graphql":
            imported.bodyMode = .graphQL
            let graphQL = (body["graphql"] as? [String: Any]) ?? [:]
            imported.graphQLBody = GraphQLDetection.body(fromObject: graphQL)
                ?? GraphQLBody(query: stringValue(graphQL["query"]) ?? "")

        case "urlencoded", "formdata":
            imported.bodyMode = .form
            let entries = (body[mode] as? [[String: Any]]) ?? []
            imported.formFields = entries.compactMap { entry in
                guard let key = entry["key"] as? String else { return nil }
                let isFile = (entry["type"] as? String) == "file"
                return FormField(
                    key: key,
                    value: isFile ? "" : (stringValue(entry["value"]) ?? ""),
                    isFile: isFile,
                    filePath: isFile ? stringValue(entry["src"]) : nil,
                    enabled: (entry["disabled"] as? Bool) != true
                )
            }
            if imported.formFields.contains(where: \.isFile) {
                result.warnings.append(
                    "\(name): file uploads are listed but not sent."
                )
            }

        case "none":
            imported.bodyMode = .none

        default:
            result.warnings.append("\(name): “\(mode)” body is not supported and was skipped.")
        }
    }

    private static func rawBodyType(from body: [String: Any]) -> RawBodyType {
        let language = ((body["options"] as? [String: Any])?["raw"] as? [String: Any])?["language"]
        switch language as? String {
        case "json": return .json
        case "xml": return .xml
        default: return .text
        }
    }

    // MARK: - Scripts

    private static func applyScripts(
        from item: [String: Any], to imported: inout APIRequest, result: inout Collection
    ) {
        for event in (item["event"] as? [[String: Any]]) ?? [] {
            let listen = event["listen"] as? String
            let script = (event["script"] as? [String: Any]) ?? [:]
            let source = PostmanScript.source(from: script["exec"])
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            guard listen == "test" else {
                // Only post-response scripts have an equivalent.
                result.warnings.append(
                    "\(imported.name): “\(listen ?? "unknown")” script was not imported."
                )
                continue
            }

            imported.postResponseScript = PostmanScript.translated(source)
            if PostmanScript.stillReferencesPostman(imported.postResponseScript) {
                result.scriptsNeedingReview.append(imported.name)
            }
        }
    }

    // MARK: - Values

    /// Postman writes numbers and booleans unquoted in places our model treats
    /// as text, so anything scalar is accepted.
    static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        case is NSNull, nil: nil
        default: String(describing: value!)
        }
    }
}

nonisolated enum PostmanImportError: LocalizedError {
    case notJSON
    case notACollection
    case noRequests

    var errorDescription: String? {
        switch self {
        case .notJSON: "That file is not valid JSON."
        case .notACollection: "That file is not a Postman collection export."
        case .noRequests: "That collection contains no requests."
        }
    }

    var recoverySuggestion: String? {
        "In Postman, use Export on the collection and pick “Collection v2.1”."
    }
}
