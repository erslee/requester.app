import Foundation

/// Gets a spec document's bytes, from the network or from a file the user picked.
///
/// Kept apart from the parsing and merging so the rest of the sync can be
/// tested without either. The session is injected for the same reason
/// `HTTPExecutor` takes one.
nonisolated struct SpecFetcher: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches the document a source points at.
    ///
    /// The URL and the headers both resolve `{{variables}}` first, so a spec
    /// behind a token can be reached with the same values the project's
    /// requests already use.
    func fetch(_ source: SpecSource, resolvingWith values: [String: String]) async throws -> Data {
        let resolved = VariableResolver.resolve(source.url, with: values)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: resolved), url.scheme != nil, url.host() != nil else {
            throw SpecFetchError.invalidURL(resolved)
        }

        var request = URLRequest(url: url)
        request.httpMethod = HTTPMethod.get.rawValue
        // Says what is wanted, for a server that would otherwise answer with the
        // Swagger UI page rather than the document.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for header in source.headers where header.enabled && !header.key.isEmpty {
            request.setValue(
                VariableResolver.resolve(header.value, with: values),
                forHTTPHeaderField: header.key
            )
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SpecFetchError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SpecFetchError.status(
                http.statusCode,
                HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized
            )
        }
        guard !data.isEmpty else { throw SpecFetchError.empty }
        return data
    }

    /// Reads a document the user picked.
    ///
    /// A file chosen through the importer is security-scoped, and reading it
    /// without taking that scope fails under the sandbox.
    static func read(_ url: URL) throws -> Data {
        let hasScope = url.startAccessingSecurityScopedResource()
        defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw SpecFetchError.unreadableFile(url.lastPathComponent)
        }
    }
}

nonisolated enum SpecFetchError: LocalizedError {
    case invalidURL(String)
    case transport(String)
    case status(Int, String)
    case empty
    case unreadableFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): "“\(url)” is not a valid URL."
        case .transport(let message): "Could not reach the document. \(message)"
        case .status(let code, let reason): "The server answered \(code) \(reason)."
        case .empty: "The server returned an empty document."
        case .unreadableFile(let name): "Could not read “\(name)”."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .invalidURL:
            "A link looks like https://api.example.com/openapi.json. "
                + "Any {{variables}} in it are resolved from this project."
        case .status(401, _), .status(403, _):
            "The document needs credentials. Add a header such as "
                + "Authorization: Bearer {{token}} to the source."
        case .status, .transport, .empty, .unreadableFile:
            nil
        }
    }
}
