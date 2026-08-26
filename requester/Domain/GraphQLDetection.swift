import Foundation

/// Recognises a GraphQL request inside a JSON body.
///
/// Shared by the curl and Postman importers: both receive GraphQL as a plain
/// JSON payload, and both should land it in the GraphQL tab rather than leaving
/// one long escaped line in Raw.
nonisolated enum GraphQLDetection {
    /// A GraphQL body, or `nil` if the JSON is not one. `query` must be present
    /// and non-empty; `operationName` and `variables` come across when there.
    static func body(fromJSON json: String) -> GraphQLBody? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))
                as? [String: Any]
        else { return nil }
        return body(fromObject: object)
    }

    static func body(fromObject object: [String: Any]) -> GraphQLBody? {
        guard let query = object["query"] as? String,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        var body = GraphQLBody(query: query)
        body.operationName = object["operationName"] as? String ?? ""

        // Re-serialised rather than passed through, so the variables arrive
        // readable instead of as the single line they were sent as.
        if let variables = object["variables"] as? [String: Any] {
            body.variablesJSON = prettyVariables(variables)
        } else if let variables = object["variables"] as? String,
                  !variables.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Postman stores GraphQL variables as a JSON string.
            body.variablesJSON = JSONFormatter.prettyPrintedIfJSON(variables)
        }
        return body
    }

    static func prettyVariables(_ variables: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: variables,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
