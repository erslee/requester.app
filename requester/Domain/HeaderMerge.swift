import Foundation

/// Combines a project's global headers with one request's own.
///
/// The request wins: a header the request names itself is never also inherited
/// from the project. Names are compared case-insensitively, because HTTP
/// header names are.
///
/// A request row that is *switched off* wins too. Toggling a row off is how a
/// request opts out of a header, and quietly putting the project's value in
/// its place would leave no way to send a request without an inherited header.
/// So `Authorization` with its toggle cleared means no `Authorization` header,
/// whatever the project says.
nonisolated enum HeaderMerge {
    /// Whether the request states its own value for this header name.
    static func isOverridden(_ header: KeyValueItem, by requestHeaders: [KeyValueItem]) -> Bool {
        guard !header.key.isEmpty else { return false }
        return requestHeaders.contains {
            $0.key.caseInsensitiveCompare(header.key) == .orderedSame
        }
    }

    /// The project headers that will actually be sent next to `requestHeaders`.
    /// Also what the editor lists as inherited, so the two can never disagree.
    static func inherited(
        from globalHeaders: [KeyValueItem], for requestHeaders: [KeyValueItem]
    ) -> [KeyValueItem] {
        globalHeaders.filter {
            $0.enabled && !$0.key.isEmpty && !isOverridden($0, by: requestHeaders)
        }
    }

    /// The request as it should be sent. Inherited headers come first, so what
    /// the request itself declares reads last -- the order the editor shows.
    static func apply(_ globalHeaders: [KeyValueItem], to request: APIRequest) -> APIRequest {
        var merged = request
        merged.headers = inherited(from: globalHeaders, for: request.headers) + request.headers
        return merged
    }
}
