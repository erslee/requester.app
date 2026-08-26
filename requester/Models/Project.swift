import Foundation

nonisolated struct Project: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var description: String = ""
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
