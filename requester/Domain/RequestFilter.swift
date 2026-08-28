import Foundation

/// Decides which saved requests a sidebar filter term matches.
///
/// The display name is passed in rather than derived here: an unnamed request
/// is labelled from its URL with the project's `{{variables}}` already
/// resolved, which is state this layer has no business reaching for. Matching
/// what the row actually reads is the point -- typing text you can see on a
/// row has to keep that row.
nonisolated enum RequestFilter {
    /// An empty term is not a filter: `nil` here is what tells the caller to
    /// leave the list alone rather than match every row one by one.
    static func normalized(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Matches against the label on the row, the URL, and the method, so both
    /// "users" and "post" narrow the list. Case- and diacritic-insensitive, the
    /// comparison a person typing into a filter field expects.
    static func matches(_ request: APIRequest, displayName: String, query: String) -> Bool {
        guard let term = normalized(query) else { return false }
        return [displayName, request.url, request.method.rawValue]
            .contains { $0.localizedStandardContains(term) }
    }
}
