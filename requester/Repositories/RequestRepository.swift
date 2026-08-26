import Foundation

/// CRUD for `APIRequest`, one file per request under a project's `requests/` directory.
nonisolated struct RequestRepository: Sendable {
    let storage: any StorageBackend

    private func path(projectID: String, requestID: String) -> String {
        "projects/\(projectID)/requests/\(requestID).json"
    }

    func create(projectID: String, name: String = "") async throws -> APIRequest {
        let existing = try await listForProject(projectID)
        let request = APIRequest(
            id: ProjectRepository.newIdentifier(),
            projectID: projectID,
            name: name,
            order: existing.count
        )
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
