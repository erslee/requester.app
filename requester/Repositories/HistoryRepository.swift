import Foundation

/// Append-only, month-partitioned JSONL history storage.
///
/// A post-response script finishes *after* the response is already persisted
/// (see `HistoryService`), so its result is written as a second, full-entry
/// "amendment" line sharing the same id -- history is never rewritten, only
/// appended to. Readers reconcile by keeping the last-written record per id.
nonisolated struct HistoryRepository: Sendable {
    static let defaultBodyTruncateBytes = 256_000

    let storage: any StorageBackend
    var bodyTruncateBytes: Int = Self.defaultBodyTruncateBytes

    static func monthKey(for date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month], from: date
        )
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    private func path(for entry: HistoryEntry) -> String {
        "history/\(entry.projectID)/\(Self.monthKey(for: entry.sentAt)).jsonl"
    }

    func append(_ entry: HistoryEntry) async throws -> HistoryEntry {
        let entry = try await writeBlobIfOversized(entry)
        try await storage.appendModelLine(entry, to: path(for: entry))
        return entry
    }

    /// Keeps the JSONL lines a readable size: a huge body is spilled to its own
    /// blob file and the inline copy is truncated, with a pointer to the full one.
    private func writeBlobIfOversized(_ entry: HistoryEntry) async throws -> HistoryEntry {
        guard var response = entry.response, response.bodySizeBytes > bodyTruncateBytes else {
            return entry
        }
        let blobPath = "history/\(entry.projectID)/blobs/\(entry.id).body"
        try await storage.writeText(response.bodyText, to: blobPath)

        response.bodyText = String(response.bodyText.prefix(bodyTruncateBytes))
        response.bodyTruncated = true
        response.bodyBlobPath = blobPath

        var truncated = entry
        truncated.response = response
        return truncated
    }

    func appendScriptResult(
        _ scriptResult: ScriptResult, to entry: HistoryEntry
    ) async throws -> HistoryEntry {
        var amended = entry
        amended.scriptResult = scriptResult
        try await storage.appendModelLine(amended, to: path(for: amended))
        return amended
    }

    /// Full body for a truncated entry, read back from its blob file.
    func fullBody(for entry: HistoryEntry) async throws -> String? {
        guard let blobPath = entry.response?.bodyBlobPath else { return nil }
        return try await storage.readText(at: blobPath)
    }

    /// Flat, unfiltered read of every entry for a project, newest first.
    func listAll(projectID: String) async throws -> [HistoryEntry] {
        try await HistoryQuery(storage: storage).search(projectID: projectID)
    }
}
