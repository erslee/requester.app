import Foundation

nonisolated struct Project: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var description: String = ""

    /// The OpenAPI document this project's requests are synced from, if any.
    ///
    /// Optional rather than defaulted: Swift's synthesized `Decodable` ignores
    /// property defaults and throws on a missing key, so a non-optional field
    /// would stop every `project.json` written before this existed from
    /// loading. An optional decodes through `decodeIfPresent` and arrives nil.
    var specSource: SpecSource?

    var createdAt: Date
    var updatedAt: Date

    init(id: String, name: String, description: String = "", now: Date = Date()) {
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = now
        self.updatedAt = now
    }
}

/// A project-scoped variable, usable as `{{key}}` in any field of any request
/// in that project.
nonisolated struct Variable: Codable, Sendable, Hashable, Identifiable {
    var key: String
    var value: String
    var updatedAt: Date
    var source: VariableSource = .manual
    var sourceRequestID: String?

    var id: String { key }

    init(
        key: String,
        value: String,
        updatedAt: Date = Date(),
        source: VariableSource = .manual,
        sourceRequestID: String? = nil
    ) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
        self.source = source
        self.sourceRequestID = sourceRequestID
    }
}
