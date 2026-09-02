import Foundation
import Synchronization

/// Sends a resolved `APIRequest` and captures the full sent/received headers,
/// timing, and body -- for both live display and the history record.
nonisolated struct HTTPExecutor: Sendable {
    struct Sent: Sendable {
        var response: ResponseRecord
        var headers: [KeyValueItem]
        var bodyText: String

        /// What URLSession measured, one entry per request actually put on the
        /// wire, so a redirect chain yields several. Empty when no metrics were
        /// reported -- a stubbed session in a test, most often.
        ///
        /// Raw dates rather than finished timeline spans: turning them into
        /// spans needs an origin to measure from, and the only correct origin
        /// is the one the *caller* started timing at. Handing that decision
        /// back is what keeps a second origin from existing at all.
        var transactions: [RequestTimeline.TransactionDates] = []
    }

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: APIRequest) async throws -> Sent {
        let urlRequest = try Self.buildURLRequest(from: request)
        let collector = TaskMetricsCollector()

        let clock = ContinuousClock()
        let start = clock.now
        let (data, response) = try await session.data(for: urlRequest, delegate: collector)
        let elapsed = start.duration(to: clock.now)

        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 0

        var record = ResponseRecord(statusCode: statusCode)
        record.reasonPhrase = HTTPURLResponse.localizedString(forStatusCode: statusCode)
            .capitalized
        record.headers = Self.keyValueItems(from: httpResponse?.allHeaderFields)
        record.bodyText = Self.text(from: data, response: response)
        record.bodySizeBytes = data.count
        record.elapsedMilliseconds = elapsed.milliseconds
        record.httpVersion = collector.networkProtocolName ?? ""

        // URLSession adds its own headers (Host, Accept-Encoding, User-Agent, ...)
        // that are absent from the URLRequest we built, so the authoritative
        // record of what went over the wire comes from the task metrics.
        let sentHeaders = collector.sentHeaders ?? urlRequest.allHTTPHeaderFields ?? [:]

        return Sent(
            response: record,
            headers: Self.keyValueItems(from: sentHeaders),
            bodyText: urlRequest.httpBody.map(Self.decodeUTF8) ?? "",
            transactions: collector.transactions
        )
    }

    // MARK: - Request building

    static func buildURLRequest(from request: APIRequest) throws -> URLRequest {
        let trimmed = request.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme != nil,
              components.host?.isEmpty == false
        else { throw HTTPExecutorError.invalidURL(request.url) }

        // Only overwrite the URL's own query when there is something to add,
        // so a query string typed straight into the URL bar survives.
        let enabledParams = request.params.filter(\.enabled)
        if !enabledParams.isEmpty {
            components.queryItems = enabledParams.map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
        }
        guard let url = components.url else { throw HTTPExecutorError.invalidURL(request.url) }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        for header in request.headers where header.enabled {
            urlRequest.setValue(header.value, forHTTPHeaderField: header.key)
        }

        try applyBody(of: request, to: &urlRequest)
        applyAuth(of: request, to: &urlRequest)
        return urlRequest
    }

    private static func applyBody(of request: APIRequest, to urlRequest: inout URLRequest) throws {
        switch request.bodyMode {
        case .none:
            break

        case .raw:
            urlRequest.httpBody = Data(request.rawBody.utf8)
            setContentTypeIfAbsent(request.rawBodyType.contentType, on: &urlRequest)

        case .form:
            // File fields are editable but not yet uploaded, matching the
            // original app: only the text fields are encoded.
            var components = URLComponents()
            components.queryItems = request.formFields
                .filter { $0.enabled && !$0.isFile }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            urlRequest.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
            setContentTypeIfAbsent("application/x-www-form-urlencoded", on: &urlRequest)

        case .graphQL:
            let graphQL = request.graphQLBody ?? GraphQLBody()
            let variablesText = graphQL.variablesJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            let variables: Any
            if variablesText.isEmpty {
                variables = [String: Any]()
            } else {
                do {
                    variables = try JSONSerialization.jsonObject(with: Data(variablesText.utf8))
                } catch {
                    throw HTTPExecutorError.invalidGraphQLVariables(variablesText)
                }
            }
            var payload: [String: Any] = ["query": graphQL.query, "variables": variables]
            if !graphQL.operationName.isEmpty {
                payload["operationName"] = graphQL.operationName
            }
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
            setContentTypeIfAbsent("application/json", on: &urlRequest)
        }
    }

    /// Basic credentials are base64-encoded into the header here rather than
    /// left to URLSession's challenge flow, so the header appears verbatim in
    /// the recorded request and the send needs no extra round trip.
    private static func applyAuth(of request: APIRequest, to urlRequest: inout URLRequest) {
        let auth = request.auth
        switch auth.type {
        case .none:
            break

        case .basic:
            let credentials = Data("\(auth.basicUsername):\(auth.basicPassword)".utf8)
            urlRequest.setValue(
                "Basic \(credentials.base64EncodedString())", forHTTPHeaderField: "Authorization"
            )

        case .bearer:
            urlRequest.setValue(
                "Bearer \(auth.bearerToken)", forHTTPHeaderField: "Authorization"
            )

        case .apiKey:
            switch auth.apiKeyIn {
            case .header:
                urlRequest.setValue(auth.apiKeyValue, forHTTPHeaderField: auth.apiKeyName)
            case .query:
                guard let url = urlRequest.url,
                      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                else { break }
                components.queryItems = (components.queryItems ?? [])
                    + [URLQueryItem(name: auth.apiKeyName, value: auth.apiKeyValue)]
                urlRequest.url = components.url
            }
        }
    }

    private static func setContentTypeIfAbsent(_ value: String, on urlRequest: inout URLRequest) {
        guard urlRequest.value(forHTTPHeaderField: "Content-Type") == nil else { return }
        urlRequest.setValue(value, forHTTPHeaderField: "Content-Type")
    }

    // MARK: - Decoding

    private static func keyValueItems(from headers: [String: String]) -> [KeyValueItem] {
        headers
            .map { KeyValueItem(key: $0.key, value: $0.value) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    private static func keyValueItems(from headers: [AnyHashable: Any]?) -> [KeyValueItem] {
        guard let headers else { return [] }
        return keyValueItems(
            from: Dictionary(
                headers.map { (String(describing: $0.key), String(describing: $0.value)) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    private static func text(from data: Data, response: URLResponse) -> String {
        if let name = response.textEncodingName,
           let encoding = String.Encoding(ianaCharSetName: name),
           let decoded = String(data: data, encoding: encoding) {
            return decoded
        }
        return decodeUTF8(data)
    }

    private static func decodeUTF8(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}

nonisolated enum HTTPExecutorError: LocalizedError {
    case invalidURL(String)
    case invalidGraphQLVariables(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Enter a URL before sending."
                : "Not a valid URL: \(url) — it needs a scheme and a host, e.g. https://example.com"
        case .invalidGraphQLVariables:
            "GraphQL variables are not valid JSON."
        }
    }
}

/// Captures the metrics URLSession only exposes through a task delegate. The
/// callback lands on the session's delegate queue, so the values are held
/// behind a mutex and read once the send has completed.
private final class TaskMetricsCollector: NSObject, URLSessionTaskDelegate, Sendable {
    private struct Captured: Sendable {
        var sentHeaders: [String: String]?
        var networkProtocolName: String?
        var transactions: [RequestTimeline.TransactionDates] = []
    }

    private let captured = Mutex(Captured())

    var sentHeaders: [String: String]? { captured.withLock(\.sentHeaders) }
    var networkProtocolName: String? { captured.withLock(\.networkProtocolName) }

    /// One entry per request actually put on the wire -- a redirect chain
    /// produces several, in the order they were followed.
    var transactions: [RequestTimeline.TransactionDates] {
        captured.withLock(\.transactions)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        // The headers and protocol describe the request that produced the
        // response, which is the last hop; the timings describe every hop.
        let all = metrics.transactionMetrics
        captured.withLock {
            $0.sentHeaders = all.last?.request.allHTTPHeaderFields
            $0.networkProtocolName = all.last?.networkProtocolName
            $0.transactions = all.map(Self.dates(from:))
        }
    }

    private static func dates(
        from transaction: URLSessionTaskTransactionMetrics
    ) -> RequestTimeline.TransactionDates {
        var dates = RequestTimeline.TransactionDates()
        dates.domainLookupStart = transaction.domainLookupStartDate
        dates.domainLookupEnd = transaction.domainLookupEndDate
        dates.connectStart = transaction.connectStartDate
        dates.connectEnd = transaction.connectEndDate
        dates.secureConnectionStart = transaction.secureConnectionStartDate
        dates.secureConnectionEnd = transaction.secureConnectionEndDate
        dates.requestStart = transaction.requestStartDate
        dates.requestEnd = transaction.requestEndDate
        dates.responseStart = transaction.responseStartDate
        dates.responseEnd = transaction.responseEndDate
        dates.isReusedConnection = transaction.isReusedConnection
        return dates
    }
}

nonisolated private extension RawBodyType {
    var contentType: String {
        switch self {
        case .text: "text/plain; charset=utf-8"
        case .json: "application/json"
        case .xml: "application/xml"
        }
    }
}

nonisolated private extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}

nonisolated private extension String.Encoding {
    init?(ianaCharSetName name: String) {
        let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        self.init(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }
}
