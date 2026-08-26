import Foundation

/// Reads an OpenAPI 3.x or Swagger 2.0 document into the operations a sync
/// works with.
///
/// JSON only. A YAML document is rejected with an error saying so rather than
/// half-parsed -- this app carries no third-party dependencies and Foundation
/// has no YAML reader, and a spec that silently parses wrong produces requests
/// that quietly hit the wrong endpoints.
///
/// Walked as loose dictionaries for the reason `PostmanImporter` is: real
/// documents bend the schema in small ways constantly, and tolerant walking
/// survives what strict decoding would reject outright.
nonisolated enum OpenAPISpec {
    /// One endpoint, in the shape the sync and the request model both want.
    /// `id` and `projectID` on `request` are left empty for the caller.
    struct Operation: Sendable, Hashable {
        /// Identity across syncs -- see `SpecLink.key`.
        var key: String
        var request: APIRequest
        /// The example body generated from the schema, remembered so a later
        /// sync can tell an untouched body from an edited one.
        var generatedBody: String
    }

    struct Document: Sendable {
        var title: String
        /// The server URL the document declares, destined for a project
        /// variable rather than being baked into every request.
        var serverURL: String
        var operations: [Operation]
        var warnings: [String]
    }

    /// The variable a spec's server URL is stored in, so every imported request
    /// can start `{{baseUrl}}/…` and one edit repoints the whole project.
    static let baseURLVariable = "baseUrl"

    private static let methods: [String: HTTPMethod] = [
        "get": .get, "post": .post, "put": .put, "patch": .patch,
        "delete": .delete, "head": .head, "options": .options,
    ]

    // MARK: - Entry point

    static func document(from data: Data) throws -> Document {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpecImportError.notJSON(looksLikeYAML: looksLikeYAML(data))
        }
        guard root["openapi"] != nil || root["swagger"] != nil else {
            throw SpecImportError.notASpec
        }

        let info = (root["info"] as? [String: Any]) ?? [:]
        var document = Document(
            title: (info["title"] as? String) ?? "API",
            serverURL: serverURL(from: root),
            operations: [],
            warnings: []
        )
        if document.serverURL.isEmpty {
            document.warnings.append(
                "The document declares no server URL, so “{{\(baseURLVariable)}}” starts empty."
            )
        }

        let paths = (root["paths"] as? [String: Any]) ?? [:]
        // Sorted, so a re-sync of an unchanged document produces the same order
        // rather than reshuffling the sidebar on every refresh.
        for path in paths.keys.sorted() {
            guard let item = paths[path] as? [String: Any] else { continue }
            append(path: path, item: item, root: root, to: &document)
        }

        guard !document.operations.isEmpty else { throw SpecImportError.noOperations }
        return document
    }

    /// Enough of a guess to give a useful error. A YAML document that happens to
    /// start with a comment or a blank line is still caught by the keys, which
    /// every spec has one of.
    private static func looksLikeYAML(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(2048), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.hasPrefix("{") else { return false }
        return head.hasPrefix("---")
            || head.contains("openapi:")
            || head.contains("swagger:")
            || head.contains("paths:")
    }

    // MARK: - Servers

    /// OpenAPI 3 puts it in `servers`; Swagger 2 splits it across `host`,
    /// `basePath`, and `schemes`.
    private static func serverURL(from root: [String: Any]) -> String {
        if let servers = root["servers"] as? [[String: Any]],
           let url = servers.first?["url"] as? String {
            // A server URL can itself be templated, e.g. https://{region}.api.dev
            return trimmingTrailingSlash(rewritingPathTemplates(in: url))
        }

        guard let host = root["host"] as? String, !host.isEmpty else { return "" }
        let scheme = (root["schemes"] as? [String])?.first ?? "https"
        let basePath = (root["basePath"] as? String) ?? ""
        return trimmingTrailingSlash("\(scheme)://\(host)\(basePath)")
    }

    private static func trimmingTrailingSlash(_ url: String) -> String {
        url.hasSuffix("/") ? String(url.dropLast()) : url
    }

    // MARK: - Operations

    private static func append(
        path: String, item: [String: Any], root: [String: Any], to document: inout Document
    ) {
        // Parameters declared on the path apply to every operation under it.
        let shared = (item["parameters"] as? [Any]) ?? []

        for method in methods.keys.sorted() {
            guard let raw = item[method] as? [String: Any], let verb = methods[method] else {
                continue
            }
            document.operations.append(
                operation(
                    path: path, method: verb, raw: raw,
                    sharedParameters: shared, root: root, warnings: &document.warnings
                )
            )
        }
    }

    private static func operation(
        path: String,
        method: HTTPMethod,
        raw: [String: Any],
        sharedParameters: [Any],
        root: [String: Any],
        warnings: inout [String]
    ) -> Operation {
        var request = APIRequest(id: "", projectID: "")
        request.method = method
        request.url = "{{\(baseURLVariable)}}" + rewritingPathTemplates(in: path)
        request.name = name(for: raw, path: path, method: method)

        // `operationId` is the spec's own stable name for the endpoint and
        // survives a path being restructured, so it is preferred. Falling back
        // to method-and-path means a document without operation ids still gets
        // stable identity, just one that moves if the path is renamed.
        let key = (raw["operationId"] as? String).map { "operationId:\($0)" }
            ?? "\(method.rawValue) \(path)"

        applyParameters(
            sharedParameters + ((raw["parameters"] as? [Any]) ?? []),
            to: &request, root: root, name: request.name, warnings: &warnings
        )

        let generatedBody = applyBody(
            raw, to: &request, root: root, name: request.name, warnings: &warnings
        )

        return Operation(key: key, request: request, generatedBody: generatedBody)
    }

    /// `Users / listUsers`, matching how the Postman importer folds folders into
    /// names -- this app has no grouping in the sidebar, so the grouping has to
    /// live in the name to stay legible.
    private static func name(
        for raw: [String: Any], path: String, method: HTTPMethod
    ) -> String {
        let leaf = (raw["summary"] as? String)?.trimmed.nonEmpty
            ?? (raw["operationId"] as? String)?.trimmed.nonEmpty
            ?? "\(method.rawValue) \(path)"

        guard let tag = (raw["tags"] as? [String])?.first?.trimmed.nonEmpty else { return leaf }
        return "\(tag) / \(leaf)"
    }

    // MARK: - Parameters

    private static func applyParameters(
        _ parameters: [Any],
        to request: inout APIRequest,
        root: [String: Any],
        name: String,
        warnings: inout [String]
    ) {
        for parameter in parameters {
            guard var parameter = parameter as? [String: Any] else { continue }

            // A parameter can be a $ref into components, like a schema can.
            if let reference = parameter["$ref"] as? String {
                guard let resolved = OpenAPISchemaExample.dereference(
                    reference, in: root, warnings: &warnings
                ) else { continue }
                parameter = resolved
            }

            guard let key = parameter["name"] as? String, !key.isEmpty else { continue }
            let value = parameterValue(parameter, root: root, warnings: &warnings)
            let item = KeyValueItem(
                key: key,
                value: value,
                // A parameter the spec does not require starts switched off, so
                // a fresh import sends the minimum the endpoint accepts.
                enabled: (parameter["required"] as? Bool) == true,
                description: (parameter["description"] as? String) ?? ""
            )

            switch parameter["in"] as? String {
            case "query": request.params.append(item)
            case "header": request.headers.append(item)
            case "path": break  // Already in the URL as {{name}}.
            case "cookie":
                warnings.append("\(name): the “\(key)” cookie parameter was not imported.")
            case "formData":
                request.bodyMode = .form
                request.formFields.append(
                    FormField(key: key, value: value, enabled: item.enabled)
                )
            default: break
            }
        }
    }

    /// A parameter's example, default, or first enum value -- or empty, which
    /// reads better in a table than an invented placeholder.
    private static func parameterValue(
        _ parameter: [String: Any], root: [String: Any], warnings: inout [String]
    ) -> String {
        if let example = parameter["example"] { return scalar(example) }
        guard let schema = parameter["schema"] ?? parameter["items"] ?? parameter as Any? else {
            return ""
        }
        guard let schema = schema as? [String: Any] else { return "" }
        if let example = schema["example"] { return scalar(example) }
        if let fallback = schema["default"] { return scalar(fallback) }
        if let choice = (schema["enum"] as? [Any])?.first { return scalar(choice) }
        return ""
    }

    // MARK: - Body

    /// Returns the generated example text, which the caller remembers so a later
    /// sync can tell an untouched body from an edited one.
    private static func applyBody(
        _ raw: [String: Any],
        to request: inout APIRequest,
        root: [String: Any],
        name: String,
        warnings: inout [String]
    ) -> String {
        // Swagger 2 carries the body as a parameter, already handled above for
        // formData; a `body` parameter has its schema inline.
        guard let content = requestBodyContent(raw, root: root, warnings: &warnings) else {
            return swagger2Body(raw, to: &request, root: root, warnings: &warnings)
        }

        // JSON first when the endpoint offers it, whatever else it also accepts.
        let jsonType = content.keys.first { $0.contains("json") }
        guard let mediaType = jsonType ?? content.keys.sorted().first else { return "" }

        if mediaType.contains("form") || mediaType.contains("multipart") {
            applyFormBody(content[mediaType], to: &request, root: root, warnings: &warnings)
            return ""
        }
        if jsonType == nil {
            warnings.append("\(name): the body is “\(mediaType)”, which is sent as raw text.")
        }

        let media = (content[mediaType] as? [String: Any]) ?? [:]
        // An example on the media type is what the API author actually wrote, so
        // it beats anything generated from the schema.
        if let example = media["example"] {
            let text = prettyJSON(example)
            request.bodyMode = .raw
            request.rawBodyType = jsonType == nil ? .text : .json
            request.rawBody = text
            return text
        }

        let generated = OpenAPISchemaExample.json(for: media["schema"], in: root)
        warnings.append(contentsOf: generated.warnings.map { "\(name): \($0)" })
        guard !generated.text.isEmpty else { return "" }

        request.bodyMode = .raw
        request.rawBodyType = jsonType == nil ? .text : .json
        request.rawBody = generated.text
        return generated.text
    }

    private static func requestBodyContent(
        _ raw: [String: Any], root: [String: Any], warnings: inout [String]
    ) -> [String: Any]? {
        guard var body = raw["requestBody"] as? [String: Any] else { return nil }
        if let reference = body["$ref"] as? String {
            guard let resolved = OpenAPISchemaExample.dereference(
                reference, in: root, warnings: &warnings
            ) else { return nil }
            body = resolved
        }
        return body["content"] as? [String: Any]
    }

    private static func applyFormBody(
        _ media: Any?, to request: inout APIRequest, root: [String: Any], warnings: inout [String]
    ) {
        request.bodyMode = .form
        let schema = (media as? [String: Any])?["schema"]
        guard let resolved = OpenAPISchemaExample.dereference(
            (schema as? [String: Any])?["$ref"] as? String ?? "",
            in: root, warnings: &warnings
        ) ?? schema as? [String: Any] else { return }

        let required = Set((resolved["required"] as? [String]) ?? [])
        for key in ((resolved["properties"] as? [String: Any]) ?? [:]).keys.sorted() {
            request.formFields.append(FormField(key: key, enabled: required.contains(key)))
        }
    }

    /// Swagger 2's `in: body` parameter, whose schema sits directly on it.
    private static func swagger2Body(
        _ raw: [String: Any], to request: inout APIRequest,
        root: [String: Any], warnings: inout [String]
    ) -> String {
        let parameters = (raw["parameters"] as? [Any]) ?? []
        guard let body = parameters.lazy.compactMap({ $0 as? [String: Any] })
            .first(where: { $0["in"] as? String == "body" })
        else { return "" }

        let generated = OpenAPISchemaExample.json(for: body["schema"], in: root)
        warnings.append(contentsOf: generated.warnings)
        guard !generated.text.isEmpty else { return "" }

        request.bodyMode = .raw
        request.rawBodyType = .json
        request.rawBody = generated.text
        return generated.text
    }

    // MARK: - Values

    /// Rewrites OpenAPI's `{id}` into this app's `{{id}}`, so a path parameter
    /// is a real variable -- resolved at send time, and tinted red until it has
    /// a value instead of being sent literally.
    static func rewritingPathTemplates(in path: String) -> String {
        path.replacing(/\{([^{}]+)\}/) { "{{\($0.1)}}" }
    }

    private static func scalar(_ value: Any) -> String {
        PostmanImporter.stringValue(value) ?? ""
    }

    private static func prettyJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        ) else { return scalar(value) }
        return String(decoding: data, as: UTF8.self)
    }
}

nonisolated enum SpecImportError: LocalizedError {
    case notJSON(looksLikeYAML: Bool)
    case notASpec
    case noOperations

    var errorDescription: String? {
        switch self {
        case .notJSON(let looksLikeYAML):
            looksLikeYAML
                ? "That looks like a YAML document, and only JSON is supported."
                : "That is not valid JSON."
        case .notASpec:
            "That file is not an OpenAPI or Swagger document."
        case .noOperations:
            "That document describes no endpoints."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notJSON(let looksLikeYAML):
            looksLikeYAML
                ? "Convert it to JSON first — for example “yq -o=json openapi.yaml > openapi.json”."
                : "Check that the file is the spec itself and not an HTML error page."
        case .notASpec:
            "The document needs a top-level “openapi” or “swagger” version field."
        case .noOperations:
            "Check that its “paths” section is not empty."
        }
    }
}

/// `nonisolated` like everything else in `Domain/`: the project defaults
/// unannotated code to the main actor, which an extension used from a
/// `nonisolated` parser must opt out of.
private extension String {
    nonisolated var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    nonisolated var nonEmpty: String? { isEmpty ? nil : self }
}
