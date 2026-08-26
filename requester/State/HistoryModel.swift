import Foundation

/// The history panel's state: which scope it is showing (a whole project, or a
/// single request) and the matching entries, newest first.
@MainActor
@Observable
final class HistoryModel {
    /// Date-grouped section, matching the "Today / Yesterday / DD-MMM-YYYY"
    /// grouping the panel renders.
    struct Group: Identifiable {
        var id: Date
        var label: String
        var entries: [HistoryEntry]
    }

    private let query: HistoryQuery
    private let history: HistoryRepository

    private(set) var projectID: String?
    private(set) var requestID: String?
    private(set) var entries: [HistoryEntry] = []
    private(set) var isLoading = false

    /// The row shown as active. Set when a request is opened (its newest send)
    /// and whenever an entry is chosen or a new one arrives.
    var selectedEntryID: String?

    var searchText = ""
    var methodFilter: HTTPMethod?
    var statusCodeFilter: String = ""

    init(query: HistoryQuery, history: HistoryRepository) {
        self.query = query
        self.history = history
    }

    var scopeDescription: String {
        requestID == nil
            ? "History for every request in this project"
            : "History for this request only"
    }

    func showProject(_ projectID: String) async {
        self.projectID = projectID
        self.requestID = nil
        await refresh()
    }

    func showRequest(projectID: String, requestID: String) async {
        self.projectID = projectID
        self.requestID = requestID
        await refresh()
    }

    func refresh() async {
        guard let projectID else {
            entries = []
            return
        }
        isLoading = true
        defer { isLoading = false }

        var filter = HistoryQuery.Filter()
        filter.requestID = requestID
        filter.text = searchText
        filter.method = methodFilter
        filter.statusCode = Int(statusCodeFilter.trimmingCharacters(in: .whitespaces))

        entries = (try? await query.search(projectID: projectID, filter: filter)) ?? []
    }

    /// The full response body for a trimmed entry, read back from its blob.
    func fullBody(for entry: HistoryEntry) async -> String? {
        try? await history.fullBody(for: entry)
    }

    /// The entry with its whole response body restored. A stored entry carries
    /// only the trimmed copy; the rest is in its blob file, and the viewer
    /// should see all of it.
    func withFullBody(_ entry: HistoryEntry) async -> HistoryEntry {
        guard entry.response?.bodyTruncated == true,
              let body = await fullBody(for: entry)
        else { return entry }

        var full = entry
        full.response?.bodyText = body
        full.response?.bodyTruncated = false
        return full
    }

    var groups: [Group] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        return entries.reduce(into: [Group]()) { groups, entry in
            let day = calendar.startOfDay(for: entry.sentAt)
            if groups.last?.id == day {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append(
                    Group(id: day, label: Self.label(for: day, today: today, calendar: calendar),
                          entries: [entry])
                )
            }
        }
    }

    private static func label(for day: Date, today: Date, calendar: Calendar) -> String {
        if day == today { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return "Yesterday"
        }
        return day.formatted(.dateTime.day().month(.abbreviated).year()).uppercased()
    }
}
