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
}
