import Foundation

/// Resolves `{{name}}` placeholders against a project's variables.
///
/// An unresolved name is left literal rather than blanked -- seeing `{{token}}`
/// arrive at the server is far easier to debug than a silently empty value.
nonisolated enum VariableResolver {
    /// A `Regex` is not `Sendable`, so this is built per use rather than
    /// cached in a static -- the cost is negligible next to the string work.
    static var pattern: Regex<(Substring, Substring)> {
        /\{\{\s*([A-Za-z0-9_.\-]+)\s*\}\}/
    }

    static func names(in text: String) -> [String] {
        text.matches(of: pattern).map { String($0.1) }
    }

    static func resolve(_ text: String, with variables: [String: String]) -> String {
        text.replacing(pattern) { match in
            variables[String(match.1)] ?? String(match.0)
        }
    }

    private static func resolve(
        _ items: [KeyValueItem], with variables: [String: String]
    ) -> [KeyValueItem] {
        items.map { item in
            var resolved = item
            resolved.key = resolve(item.key, with: variables)
            resolved.value = resolve(item.value, with: variables)
            return resolved
        }
    }

    /// A file field's value is a path, not a template, so it is left alone.
    private static func resolve(
        _ fields: [FormField], with variables: [String: String]
    ) -> [FormField] {
        fields.map { field in
            guard !field.isFile else { return field }
            var resolved = field
            resolved.value = resolve(field.value, with: variables)
            return resolved
        }
    }

    /// Substitutes across url, params, headers, body, GraphQL, form fields, and auth.
    static func resolve(_ request: APIRequest, with variables: [String: String]) -> APIRequest {
        var resolved = request
        resolved.url = resolve(request.url, with: variables)
        resolved.params = resolve(request.params, with: variables)
        resolved.headers = resolve(request.headers, with: variables)
        resolved.rawBody = resolve(request.rawBody, with: variables)
        resolved.formFields = resolve(request.formFields, with: variables)

        if var graphQL = request.graphQLBody {
            graphQL.query = resolve(graphQL.query, with: variables)
            graphQL.variablesJSON = resolve(graphQL.variablesJSON, with: variables)
            resolved.graphQLBody = graphQL
        }

        resolved.auth.basicUsername = resolve(request.auth.basicUsername, with: variables)
        resolved.auth.basicPassword = resolve(request.auth.basicPassword, with: variables)
        resolved.auth.bearerToken = resolve(request.auth.bearerToken, with: variables)
        resolved.auth.apiKeyValue = resolve(request.auth.apiKeyValue, with: variables)

        return resolved
    }
}
