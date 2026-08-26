import Foundation

/// CRUD for a project's variables, stored as one `variables/<projectID>.json`
/// map keyed by variable name.
nonisolated struct VariableRepository: Sendable {
    let storage: any StorageBackend

    private func path(for projectID: String) -> String {
        "variables/\(projectID).json"
    }

    func getAll(projectID: String) async throws -> [String: Variable] {
        try await storage.readModel([String: Variable].self, at: path(for: projectID)) ?? [:]
    }

    func values(projectID: String) async throws -> [String: String] {
        try await getAll(projectID: projectID).mapValues(\.value)
    }

    func setMany(
        projectID: String,
        writes: [String: String],
        source: VariableSource,
        sourceRequestID: String? = nil
    ) async throws {
        guard !writes.isEmpty else { return }
        var existing = try await getAll(projectID: projectID)
        let now = Date()
        for (key, value) in writes {
            existing[key] = Variable(
                key: key,
                value: value,
                updatedAt: now,
                source: source,
                sourceRequestID: sourceRequestID
            )
        }
        try await storage.writeModel(existing, to: path(for: projectID))
    }

    func setOne(projectID: String, key: String, value: String) async throws {
        try await setMany(projectID: projectID, writes: [key: value], source: .manual)
    }

    func delete(projectID: String, key: String) async throws {
        var existing = try await getAll(projectID: projectID)
        guard existing.removeValue(forKey: key) != nil else { return }
        try await storage.writeModel(existing, to: path(for: projectID))
    }
}
