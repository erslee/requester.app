import Foundation

/// Streaming, date-range-narrowing search over month-partitioned history JSONL.
///
/// Whole files outside the requested range are skipped by comparing filenames
/// alone -- no file is opened. Within a file, a cheap raw-line substring
/// pre-filter runs before paying for full JSON decoding of non-matching lines.
nonisolated struct HistoryQuery: Sendable {
    let storage: any StorageBackend

    struct Filter: Sendable {
        var dateFrom: Date?
        var dateTo: Date?
        var text: String = ""
        var method: HTTPMethod?
        var statusCode: Int?
        var requestID: String?

        init() {}
    }

    func search(projectID: String, filter: Filter = Filter()) async throws -> [HistoryEntry] {
        let filenames = try await storage.listDirectory(at: "history/\(projectID)")
        let monthKeys = filenames
            .filter { $0.hasSuffix(".jsonl") }
            .map { String($0.dropLast(".jsonl".count)) }
            .sorted()

        let fromKey = filter.dateFrom.map(HistoryRepository.monthKey(for:))
        let toKey = filter.dateTo.map(HistoryRepository.monthKey(for:))
        let candidates = monthKeys.filter { key in
            (fromKey.map { key >= $0 } ?? true) && (toKey.map { key <= $0 } ?? true)
        }

        let query = filter.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let calendar = Calendar.current

        // Keyed by entry id so an amendment line (same id, written later)
        // replaces the original record it amends.
        var byID: [String: HistoryEntry] = [:]

        for monthKey in candidates {
            guard let content = try await storage.readText(
                at: "history/\(projectID)/\(monthKey).jsonl"
            ) else { continue }

            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                if !query.isEmpty, !line.lowercased().contains(query) { continue }
                if let requestID = filter.requestID, !line.contains(requestID) { continue }
                guard let entry = try? JSONCoding.decoder.decode(
                    HistoryEntry.self, from: Data(line.utf8)
                ) else { continue }

                if let from = filter.dateFrom,
                   calendar.startOfDay(for: entry.sentAt) < calendar.startOfDay(for: from) {
                    continue
                }
                if let to = filter.dateTo,
                   calendar.startOfDay(for: entry.sentAt) > calendar.startOfDay(for: to) {
                    continue
                }
                if let method = filter.method, entry.requestSnapshot.method != method { continue }
                if let statusCode = filter.statusCode,
                   entry.response?.statusCode != statusCode {
                    continue
                }
                if let requestID = filter.requestID, entry.requestID != requestID { continue }

                byID[entry.id] = entry
            }
        }

        return byID.values.sorted { $0.sentAt > $1.sentAt }
    }

    /// When each request was last sent, for the sidebar's used-order list.
    ///
    /// Deliberately not `search` plus a `map`. That decodes every stored entry
    /// in full -- request snapshot, sent headers, and a response body up to the
    /// 256 KB spill threshold -- and this runs once per project load for a
    /// result that is two fields wide. `Sent` below decodes only those two, so
    /// the cost tracks the number of sends rather than their size.
    ///
    /// Amendment lines need no reconciliation here: a second line sharing an
    /// id repeats the `sentAt` of the send it amends, so taking the maximum per
    /// request is right whichever lines are read.
    func lastUsed(projectID: String) async throws -> [String: Date] {
        /// The two fields this needs, so the rest of a line is never decoded.
        struct Sent: Decodable {
            var requestID: String?
            var sentAt: Date
        }

        let filenames = try await storage.listDirectory(at: "history/\(projectID)")
        var lastUsed: [String: Date] = [:]

        for filename in filenames.filter({ $0.hasSuffix(".jsonl") }) {
            guard let content = try await storage.readText(
                at: "history/\(projectID)/\(filename)"
            ) else { continue }

            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let sent = try? JSONCoding.decoder.decode(
                    Sent.self, from: Data(line.utf8)
                ), let requestID = sent.requestID, !requestID.isEmpty else { continue }

                if sent.sentAt > lastUsed[requestID] ?? .distantPast {
                    lastUsed[requestID] = sent.sentAt
                }
            }
        }

        return lastUsed
    }
}
