import Foundation

/// One row of a Params / Headers table, and the shape response headers are
/// recorded in. `enabled` lets a row be kept but not sent.
nonisolated struct KeyValueItem: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var key: String = ""
    var value: String = ""
    var enabled: Bool = true
    var description: String = ""

    /// `id` is a UI identity only -- it is deliberately not persisted, so a
    /// decoded item gets a fresh one and stored files stay free of churn.
    private enum CodingKeys: String, CodingKey {
        case key, value, enabled, description
    }

    init(key: String = "", value: String = "", enabled: Bool = true, description: String = "") {
        self.key = key
        self.value = value
        self.enabled = enabled
        self.description = description
    }

    var isBlank: Bool { key.isEmpty && value.isEmpty }
}

nonisolated struct FormField: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var key: String = ""
    var value: String = ""
    var isFile: Bool = false
    var filePath: String?
    var contentType: String?
    var enabled: Bool = true

    private enum CodingKeys: String, CodingKey {
        case key, value, isFile, filePath, contentType, enabled
    }

    init(
        key: String = "",
        value: String = "",
        isFile: Bool = false,
        filePath: String? = nil,
        contentType: String? = nil,
        enabled: Bool = true
    ) {
        self.key = key
        self.value = value
        self.isFile = isFile
        self.filePath = filePath
        self.contentType = contentType
        self.enabled = enabled
    }
}

nonisolated struct AuthConfig: Codable, Sendable, Hashable {
    var type: AuthType = .none
    var basicUsername: String = ""
    var basicPassword: String = ""
    var bearerToken: String = ""
    var apiKeyName: String = ""
    var apiKeyValue: String = ""
    var apiKeyIn: APIKeyLocation = .header

    init() {}
}

nonisolated struct GraphQLBody: Codable, Sendable, Hashable {
    var query: String = ""
    var variablesJSON: String = "{}"
    var operationName: String = ""

    init(query: String = "", variablesJSON: String = "{}", operationName: String = "") {
        self.query = query
        self.variablesJSON = variablesJSON
        self.operationName = operationName
    }
}

/// A saved request. Stored one file per request under a project's `requests/`
/// directory. Field values keep their unresolved `{{variable}}` templates --
/// substitution happens at send time (see `VariableResolver`).
nonisolated struct APIRequest: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var projectID: String
    var name: String = ""
    var method: HTTPMethod = .get
    var url: String = ""
    var params: [KeyValueItem] = []
    var headers: [KeyValueItem] = []
    var bodyMode: BodyMode = .none
    var rawBody: String = ""
    var rawBodyType: RawBodyType = .json
    var formFields: [FormField] = []
    var graphQLBody: GraphQLBody?
    var auth = AuthConfig()
    var postResponseScript: String = ""
    var scriptTimeoutSeconds: Double = 5

    /// Set on requests an OpenAPI spec created, `nil` on ones made by hand --
    /// which is what keeps a sync from touching a hand-written request.
    ///
    /// Optional rather than defaulted for the same reason as `Project.specSource`:
    /// a non-optional field would stop every request file written before this
    /// existed from decoding.
    var spec: SpecLink?

    /// The folder this request sits in, outermost first -- `["Users", "Admin"]`
    /// is `Users ▸ Admin`. Empty means the project's top level.
    ///
    /// A path rather than a folder id: a folder has no existence beyond the
    /// requests in it and the project's list of ones made by hand, so there is
    /// nothing for an id to point at. Optional for the same reason as `spec`
    /// above -- a non-optional field would stop every request file written
    /// before this existed from decoding.
    var folderPath: [String]?

    /// The folder as the rest of the app wants it: `nil` and `[]` both mean
    /// the top level.
    var folder: [String] {
        get { folderPath ?? [] }
        set { folderPath = newValue.isEmpty ? nil : newValue }
    }

    /// Whether this request is starred, listed on the sidebar's Favorites tab.
    ///
    /// Optional for the same reason as `spec` and `folderPath` above -- a
    /// non-optional field would stop every request file written before this
    /// existed from decoding. `nil` and `false` mean the same thing.
    var favorite: Bool?

    /// The flag as the rest of the app wants it. Clearing writes `nil` rather
    /// than `false`, so unstarring leaves the file as it was before.
    var isFavorite: Bool {
        get { favorite ?? false }
        set { favorite = newValue ? true : nil }
    }

    var order: Int = 0
    var createdAt: Date
    var updatedAt: Date

    init(id: String, projectID: String, name: String = "", order: Int = 0, now: Date = Date()) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.order = order
        self.createdAt = now
        self.updatedAt = now
    }

    /// The request without the blank trailing rows the editor's tables keep
    /// around for adding entries. This is what gets saved and sent -- the
    /// placeholder rows are a UI affordance only.
    var normalized: APIRequest {
        var copy = self
        copy.params = params.filter { !$0.isBlank }
        copy.headers = headers.filter { !$0.isBlank }
        copy.formFields = formFields.filter { !($0.key.isEmpty && $0.value.isEmpty && !$0.isFile) }
        return copy
    }

    /// What "has this changed?" should compare: the authored content, with the
    /// bookkeeping timestamps set aside. Without this, saving only the name
    /// bumps `updatedAt` and the request looks permanently unsaved.
    var editableContent: APIRequest {
        var copy = normalized
        copy.createdAt = .distantPast
        copy.updatedAt = .distantPast
        // The spec link is bookkeeping, not authored content. A sync that marks
        // an operation removed must not light up the editor's unsaved-changes
        // dot on a request the user has not touched.
        copy.spec = nil
        // Starring is the same kind of bookkeeping: it is written straight to
        // disk from the sidebar, and must not make an open draft look unsaved.
        copy.favorite = nil
        return copy
    }
}
