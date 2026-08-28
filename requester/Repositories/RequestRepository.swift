import Foundation

/// CRUD for `APIRequest`, one file per request under a project's `requests/` directory.
nonisolated struct RequestRepository: Sendable {
    let storage: any StorageBackend

    private func path(projectID: String, requestID: String) -> String {
        "projects/\(projectID)/requests/\(requestID).json"
    }

    func create(
        projectID: String, name: String = "", folder: [String] = []
    ) async throws -> APIRequest {
        let existing = try await listForProject(projectID)
        var request = APIRequest(
            id: ProjectRepository.newIdentifier(),
            projectID: projectID,
            name: name,
            order: existing.count
        )
        request.folder = folder
        try await storage.writeModel(request, to: path(projectID: projectID, requestID: request.id))
        return request
    }

    func get(projectID: String, requestID: String) async throws -> APIRequest? {
        try await storage.readModel(
            APIRequest.self, at: path(projectID: projectID, requestID: requestID)
        )
    }

    func listForProject(_ projectID: String) async throws -> [APIRequest] {
        var requests: [APIRequest] = []
        for filename in try await storage.listDirectory(at: "projects/\(projectID)/requests")
        where filename.hasSuffix(".json") {
            let requestID = String(filename.dropLast(".json".count))
            if let request = try? await get(projectID: projectID, requestID: requestID) {
                requests.append(request)
            }
        }
        return requests.sorted { $0.order < $1.order }
    }

    func save(_ request: APIRequest) async throws -> APIRequest {
        var updated = request
        updated.updatedAt = Date()
        try await storage.writeModel(
            updated, to: path(projectID: updated.projectID, requestID: updated.id)
        )
        return updated
    }

    func delete(projectID: String, requestID: String) async throws {
        try await storage.delete(at: path(projectID: projectID, requestID: requestID))
    }

    /// Moves one request into a folder. `[]` puts it at the project's top level.
    func move(
        projectID: String, requestID: String, to folder: [String]
    ) async throws -> APIRequest? {
        guard var request = try await get(projectID: projectID, requestID: requestID),
              request.folder != folder
        else { return nil }
        request.folder = folder
        return try await save(request)
    }

    /// Re-parents a folder and everything under it, by rewriting the paths that
    /// start with `from`. Renaming and moving a folder are the same operation:
    /// only the last component differs.
    ///
    /// Returns the requests it changed, so the caller can tell whether anything
    /// actually moved.
    @discardableResult
    func moveFolder(
        projectID: String, from: [String], to: [String]
    ) async throws -> [APIRequest] {
        var moved: [APIRequest] = []
        for request in try await listForProject(projectID) {
            guard let path = FolderTree.rewriting(request.folder, from: from, to: to),
                  path != request.folder
            else { continue }
            var updated = request
            updated.folder = path
            moved.append(try await save(updated))
        }
        return moved
    }

    /// Deletes a folder's whole subtree -- every request at or under `folder`.
    /// Nothing else in this app deletes requests the user did not name, so this
    /// is only ever reached from an explicit, confirmed delete.
    func deleteFolder(projectID: String, folder: [String]) async throws {
        for request in try await listForProject(projectID)
        where FolderTree.isSelfOrDescendant(request.folder, of: folder) {
            try await delete(projectID: projectID, requestID: request.id)
        }
    }

    func reorder(projectID: String, orderedRequestIDs: [String]) async throws {
        for (index, requestID) in orderedRequestIDs.enumerated() {
            guard var request = try await get(projectID: projectID, requestID: requestID),
                  request.order != index
            else { continue }
            request.order = index
            _ = try await save(request)
        }
    }
}
