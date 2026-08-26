import Foundation

/// CRUD for `Project` metadata. Requests live as sibling files under
/// `projects/<projectID>/requests/` -- see `RequestRepository`.
nonisolated struct ProjectRepository: Sendable {
    let storage: any StorageBackend

    private func path(for projectID: String) -> String {
        "projects/\(projectID)/project.json"
    }

    func create(name: String, description: String = "") async throws -> Project {
        let project = Project(id: Self.newIdentifier(), name: name, description: description)
        try await storage.writeModel(project, to: path(for: project.id))
        return project
    }

    func get(_ projectID: String) async throws -> Project? {
        try await storage.readModel(Project.self, at: path(for: projectID))
    }

    func listAll() async throws -> [Project] {
        var projects: [Project] = []
        for projectID in try await storage.listDirectory(at: "projects") {
            if let project = try? await get(projectID) {
                projects.append(project)
            }
        }
        return projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func rename(_ projectID: String, to name: String) async throws -> Project {
        guard var project = try await get(projectID) else {
            throw StorageError.notFound("project \(projectID)")
        }
        project.name = name
        project.updatedAt = Date()
        try await storage.writeModel(project, to: path(for: projectID))
        return project
    }

    /// Deleting a project takes its requests, history, and variables with it.
    func delete(_ projectID: String) async throws {
        try await storage.deleteTree(at: "projects/\(projectID)")
        try await storage.deleteTree(at: "history/\(projectID)")
        try await storage.delete(at: "variables/\(projectID).json")
    }

    /// Matches the identifier format the Python app wrote: a bare 32-character
    /// hex UUID, so both apps can read the same folder layout.
    static func newIdentifier() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

nonisolated enum StorageError: LocalizedError {
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let what): "No such \(what)."
        }
    }
}
