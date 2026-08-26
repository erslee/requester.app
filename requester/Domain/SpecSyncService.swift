import Foundation

/// Runs one spec sync end to end: get the document, parse it, work out what
/// changed, and write it.
///
/// Sits alongside `HistoryService` as the other place a whole user-facing
/// operation is orchestrated over the repositories, so the state layer above
/// stays thin and the whole flow stays testable without a window.
///
/// Adding a spec, refreshing a link, and re-uploading a file are the same
/// operation -- only `Source` differs. That is deliberate: there is one merge
/// path, so a re-upload cannot behave differently from a refresh.
nonisolated struct SpecSyncService: Sendable {
    let requests: RequestRepository
    let projects: ProjectRepository
    let variables: VariableRepository
    let fetcher: SpecFetcher

    /// Where this run's bytes come from.
    enum Source: Sendable {
        /// Re-read whatever the project's saved source points at. Only valid
        /// for a `.url` source -- a file cannot be re-read without the user
        /// picking it again, which is what `.file` is for.
        case saved
        case file(URL)
    }

    struct Summary: Sendable {
        var title: String
        var added: Int
        var updated: Int
        var restored: Int
        var removed: Int
        var unchanged: Int
        var warnings: [String]

        var isFirstImport = false

        var hasChanges: Bool { added + updated + restored + removed > 0 }
    }

    // MARK: - Running a sync

    func sync(projectID: String, using source: Source) async throws -> Summary {
        guard let project = try await projects.get(projectID) else {
            throw StorageError.notFound("project \(projectID)")
        }
        guard var specSource = project.specSource else {
            throw SpecSyncError.noSource
        }

        let data: Data
        switch source {
        case .saved:
            guard specSource.kind == .url else { throw SpecSyncError.fileNeedsReupload }
            let values = try await variables.values(projectID: projectID)
            data = try await fetcher.fetch(specSource, resolvingWith: values)
        case .file(let url):
            data = try SpecFetcher.read(url)
            specSource.kind = .file
            specSource.fileName = url.lastPathComponent
        }

        let document = try OpenAPISpec.document(from: data)
        let existing = try await requests.listForProject(projectID)
        let plan = SpecSync.plan(existing: existing, incoming: document.operations)

        // The plan is complete before anything is written. A document that fails
        // to parse, or a fetch that fails, leaves the project untouched.
        try await apply(plan, projectID: projectID, existing: existing)
        try await seedBaseURL(document, projectID: projectID)

        specSource.lastSyncedAt = Date()
        _ = try await projects.setSpecSource(specSource, for: projectID)

        return Summary(
            title: document.title,
            added: plan.added.count,
            updated: plan.updated.count,
            restored: plan.restored.count,
            removed: plan.removed.count,
            unchanged: plan.unchangedCount,
            warnings: document.warnings,
            isFirstImport: existing.allSatisfy { $0.spec == nil }
        )
    }

    // MARK: - Applying

    private func apply(
        _ plan: SpecSync.Plan, projectID: String, existing: [APIRequest]
    ) async throws {
        for request in plan.writes {
            _ = try await requests.save(request)
        }

        // New endpoints land after everything already there, in document order.
        var order = (existing.map(\.order).max() ?? -1) + 1
        for operation in plan.added {
            var request = operation.request
            request.id = ProjectRepository.newIdentifier()
            request.projectID = projectID
            request.order = order
            request.spec = SpecLink(key: operation.key, generatedBody: operation.generatedBody)
            _ = try await requests.save(request)
            order += 1
        }

        try await sinkRemoved(projectID: projectID)
    }

    /// Moves tombstoned requests below the live ones, so a project whose spec
    /// has churned does not interleave gone endpoints with current ones.
    private func sinkRemoved(projectID: String) async throws {
        let all = try await requests.listForProject(projectID)
        let live = all.filter { $0.spec?.isRemoved != true }
        let removed = all.filter { $0.spec?.isRemoved == true }
        guard !removed.isEmpty else { return }
        try await requests.reorder(
            projectID: projectID, orderedRequestIDs: (live + removed).map(\.id)
        )
    }

    /// Puts the document's server URL in `{{baseUrl}}` the first time, and
    /// leaves it alone afterwards.
    ///
    /// Never overwritten on a refresh: pointing the variable at staging is the
    /// obvious thing to do with it, and a sync that reset it to the document's
    /// production URL every time would be a trap.
    private func seedBaseURL(_ document: OpenAPISpec.Document, projectID: String) async throws {
        guard !document.serverURL.isEmpty else { return }
        let existing = try await variables.getAll(projectID: projectID)
        guard existing[OpenAPISpec.baseURLVariable] == nil else { return }
        try await variables.setMany(
            projectID: projectID,
            writes: [OpenAPISpec.baseURLVariable: document.serverURL],
            source: .manual
        )
    }
}

nonisolated enum SpecSyncError: LocalizedError {
    case noSource
    case fileNeedsReupload

    var errorDescription: String? {
        switch self {
        case .noSource: "This project has no API document attached."
        case .fileNeedsReupload: "This document came from a file, which has to be uploaded again."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noSource: "Add one with a link or a file first."
        case .fileNeedsReupload: "Use “Replace File…” and pick the updated document."
        }
    }
}
