import Foundation
import Testing
@testable import requester

/// History is append-only, so the reconciliation rule -- a later line with the
/// same id wins -- is what keeps a script amendment from duplicating an entry.
struct HistoryTests {
    private func entry(
        id: String, projectID: String = "p1", requestID: String? = "r1",
        method: HTTPMethod = .get, url: String = "https://example.com/a",
        sentAt: Date, status: Int? = 200
    ) -> HistoryEntry {
        var request = APIRequest(id: requestID ?? "", projectID: projectID)
        request.method = method
        var entry = HistoryEntry(
            id: id, projectID: projectID, requestID: requestID,
            requestSnapshot: request, resolvedURL: url, sentAt: sentAt
        )
        if let status {
            var response = ResponseRecord(statusCode: status)
            response.bodyText = "{\"ok\":true}"
            response.bodySizeBytes = 11
            entry.response = response
        }
        return entry
    }

    @Test func amendmentLineReplacesRatherThanDuplicatesTheEntry() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let history = HistoryRepository(storage: storage)
        let original = try await history.append(
            entry(id: "e1", sentAt: .now)
        )

        // Act -- the script result arrives after the response was persisted
        var result = ScriptResult(ran: true, succeeded: true)
        result.variablesWritten = ["token": "abc"]
        _ = try await history.appendScriptResult(result, to: original)

        // Assert -- one entry, now carrying the script result
        let entries = try await history.listAll(projectID: "p1")
        #expect(entries.count == 1)
        #expect(entries.first?.scriptResult?.variablesWritten == ["token": "abc"])
    }

    @Test func spillsAnOversizedBodyToABlobAndTruncatesInline() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let history = HistoryRepository(storage: storage, bodyTruncateBytes: 100)
        var oversized = entry(id: "e1", sentAt: .now)
        oversized.response?.bodyText = String(repeating: "x", count: 500)
        oversized.response?.bodySizeBytes = 500

        // Act
        let stored = try await history.append(oversized)

        // Assert
        #expect(stored.response?.bodyTruncated == true)
        #expect(stored.response?.bodyText.count == 100)
        #expect(try await history.fullBody(for: stored)?.count == 500)
    }

    @Test func returnsEntriesNewestFirstAcrossMonthFiles() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let history = HistoryRepository(storage: storage)
        let june = try #require(Calendar.current.date(from: .init(year: 2026, month: 6, day: 10)))
        let july = try #require(Calendar.current.date(from: .init(year: 2026, month: 7, day: 10)))
        _ = try await history.append(entry(id: "june", sentAt: june))
        _ = try await history.append(entry(id: "july", sentAt: july))

        // Act
        let entries = try await history.listAll(projectID: "p1")

        // Assert
        #expect(entries.map(\.id) == ["july", "june"])
    }

    @Test func filtersByRequestMethodStatusAndText() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let history = HistoryRepository(storage: storage)
        let now = Date()
        _ = try await history.append(
            entry(id: "a", requestID: "r1", method: .get, url: "https://example.com/users", sentAt: now)
        )
        _ = try await history.append(
            entry(id: "b", requestID: "r2", method: .post, url: "https://example.com/login",
                  sentAt: now, status: 401)
        )
        let query = HistoryQuery(storage: storage)

        // Act / Assert -- request scope
        var filter = HistoryQuery.Filter()
        filter.requestID = "r2"
        #expect(try await query.search(projectID: "p1", filter: filter).map(\.id) == ["b"])

        // Act / Assert -- method
        filter = HistoryQuery.Filter()
        filter.method = .get
        #expect(try await query.search(projectID: "p1", filter: filter).map(\.id) == ["a"])

        // Act / Assert -- status code
        filter = HistoryQuery.Filter()
        filter.statusCode = 401
        #expect(try await query.search(projectID: "p1", filter: filter).map(\.id) == ["b"])

        // Act / Assert -- free text over the raw line
        filter = HistoryQuery.Filter()
        filter.text = "login"
        #expect(try await query.search(projectID: "p1", filter: filter).map(\.id) == ["b"])
    }

    @Test func skipsMonthFilesOutsideTheDateRange() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let history = HistoryRepository(storage: storage)
        let june = try #require(Calendar.current.date(from: .init(year: 2026, month: 6, day: 10)))
        let july = try #require(Calendar.current.date(from: .init(year: 2026, month: 7, day: 10)))
        _ = try await history.append(entry(id: "june", sentAt: june))
        _ = try await history.append(entry(id: "july", sentAt: july))

        // Act
        var filter = HistoryQuery.Filter()
        filter.dateFrom = july
        let entries = try await HistoryQuery(storage: storage)
            .search(projectID: "p1", filter: filter)

        // Assert
        #expect(entries.map(\.id) == ["july"])
    }

    // MARK: - Used order

    /// The sidebar's History tab orders requests by their most recent send, so
    /// what matters is that a request is reported once, at its newest.
    @Test func reportsTheNewestSendPerRequest() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let history = HistoryRepository(storage: storage)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = old.addingTimeInterval(3600)
        _ = try await history.append(entry(id: "a", requestID: "r1", sentAt: old))
        _ = try await history.append(entry(id: "b", requestID: "r1", sentAt: recent))
        _ = try await history.append(entry(id: "c", requestID: "r2", sentAt: old))

        // Act
        let lastUsed = try await HistoryQuery(storage: storage).lastUsed(projectID: "p1")

        // Assert -- one date per request, the later one where it was sent twice
        #expect(lastUsed == ["r1": recent, "r2": old])
    }

    /// A send made from a history entry has no saved request behind it. There
    /// is nothing in the sidebar for it to order, so it must not invent a row.
    @Test func ignoresSendsWithNoRequestBehindThem() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let history = HistoryRepository(storage: storage)
        _ = try await history.append(entry(id: "a", requestID: nil, sentAt: .now))

        // Act / Assert
        #expect(try await HistoryQuery(storage: storage).lastUsed(projectID: "p1").isEmpty)
    }

    /// A script result is appended as a second line sharing the entry's id.
    /// Both lines carry the same `sentAt`, so the answer must not shift.
    @Test func isUnaffectedByAmendmentLines() async throws {
        // Arrange
        let storage = InMemoryStorage()
        let history = HistoryRepository(storage: storage)
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        let original = try await history.append(entry(id: "e1", requestID: "r1", sentAt: sentAt))
        var result = ScriptResult(ran: true, succeeded: true)
        result.variablesWritten = ["token": "abc"]
        _ = try await history.appendScriptResult(result, to: original)

        // Act
        let lastUsed = try await HistoryQuery(storage: storage).lastUsed(projectID: "p1")

        // Assert
        #expect(lastUsed == ["r1": sentAt])
    }

    @Test func reportsNothingForAProjectWithNoHistory() async throws {
        // Act / Assert
        #expect(
            try await HistoryQuery(storage: InMemoryStorage())
                .lastUsed(projectID: "nope").isEmpty
        )
    }
}
