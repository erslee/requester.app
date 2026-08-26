import Foundation

nonisolated struct ResponseRecord: Codable, Sendable, Hashable {
    var statusCode: Int
    var reasonPhrase: String = ""
    var headers: [KeyValueItem] = []
    var bodyText: String = ""
    var bodyTruncated: Bool = false
    var bodyBlobPath: String?
    var bodySizeBytes: Int = 0
    var elapsedMilliseconds: Double = 0
    var httpVersion: String = ""

    init(statusCode: Int) {
        self.statusCode = statusCode
    }
}

nonisolated struct ScriptResult: Codable, Sendable, Hashable {
    var ran: Bool = false
    var succeeded: Bool = false
    var error: String?
    var variablesWritten: [String: String] = [:]
    var output: String = ""

    init(ran: Bool = false, succeeded: Bool = false, error: String? = nil) {
        self.ran = ran
        self.succeeded = succeeded
        self.error = error
    }
}

/// One recorded send. Written to an append-only, month-partitioned JSONL file.
///
/// `requestSnapshot` keeps the *unresolved* request so the entry can be
/// re-edited and resent, while `resolvedURL` / `requestHeadersSent` /
/// `requestBodySent` record what actually went over the wire.
nonisolated struct HistoryEntry: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var projectID: String
    var requestID: String?
    var requestSnapshot: APIRequest
    var resolvedURL: String
    var requestHeadersSent: [KeyValueItem] = []
    var requestBodySent: String = ""
    var response: ResponseRecord?
    var error: String?
    var sentAt: Date
    var timeMilliseconds: Double = 0
    var scriptResult: ScriptResult?

    init(
        id: String,
        projectID: String,
        requestID: String?,
        requestSnapshot: APIRequest,
        resolvedURL: String,
        sentAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.requestID = requestID
        self.requestSnapshot = requestSnapshot
        self.resolvedURL = resolvedURL
        self.sentAt = sentAt
    }
}
