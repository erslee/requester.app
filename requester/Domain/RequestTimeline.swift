import Foundation

/// Where one send's time went: the app's own stages, and the network phases
/// underneath the one that did the sending.
///
/// Times are milliseconds relative to the moment the send began, so the view
/// can lay a waterfall out without knowing any absolute dates.
///
/// The two halves arrive at different moments, which is the whole shape of this
/// type. The app stages are measured as they happen and can be reported live.
/// The network phases exist only once URLSession hands over its metrics, after
/// the task has completed -- there is no API that says "DNS finished" while it
/// is finishing. So a timeline gains detail when the response lands rather than
/// filling in smoothly.
nonisolated struct RequestTimeline: Codable, Sendable, Hashable {
    /// What a span measures.
    ///
    /// Stored by raw value, like `BodyMode` and `AuthType`. An entry written by
    /// a newer build carrying a kind this one has never heard of will not
    /// decode -- the same trade the rest of the format already makes.
    enum Kind: String, Codable, Sendable, CaseIterable {
        // The app's own stages, in the order `HistoryService` runs them.
        case prepare
        case send
        case saveHistory
        case script
        case saveScriptResult

        // The network phases inside `send`, one set per redirect hop.
        case dns
        case connect
        case tls
        case request
        case waiting
        case download

        var label: String {
            switch self {
            case .prepare: "prepare"
            case .send: "send"
            case .saveHistory: "save history"
            case .script: "script"
            case .saveScriptResult: "save variables"
            case .dns: "DNS"
            case .connect: "connect"
            case .tls: "TLS"
            case .request: "request"
            case .waiting: "waiting (TTFB)"
            case .download: "download"
            }
        }

        /// What the live indicator says while this stage is the one running.
        /// Only the app stages are ever live; the network phases are known
        /// only in retrospect.
        var runningLabel: String {
            switch self {
            case .prepare: "Preparing…"
            case .send: "Sending…"
            case .saveHistory: "Saving…"
            case .script: "Running script…"
            case .saveScriptResult: "Saving variables…"
            default: label
            }
        }

        var isNetwork: Bool {
            switch self {
            case .dns, .connect, .tls, .request, .waiting, .download: true
            default: false
            }
        }

        /// TLS is measured *inside* the connect phase, so the view indents it
        /// rather than showing it as a sibling that overlaps its neighbour.
        var isNestedInPrevious: Bool { self == .tls }
    }

    struct Span: Codable, Sendable, Hashable, Identifiable {
        var kind: Kind

        /// Which redirect hop this belongs to, numbered from 0. `nil` for the
        /// app stages, which happen once however many hops the send took.
        var hop: Int?

        var startMilliseconds: Double
        var durationMilliseconds: Double

        var id: String { "\(kind.rawValue)-\(hop.map(String.init) ?? "app")" }
        var endMilliseconds: Double { startMilliseconds + durationMilliseconds }
    }

    var spans: [Span] = []

    /// Hops that went out over a connection that was already open. Recorded so
    /// the view can say "connection reused" rather than leave an unexplained
    /// hole where DNS, connect and TLS would otherwise be.
    var reusedConnectionHops: Set<Int> = []

    /// Wall-clock time for the whole pipeline, which is longer than the network
    /// spans: it includes preparing the request and everything done after the
    /// response arrived.
    var totalMilliseconds: Double = 0

    var isEmpty: Bool { spans.isEmpty }

    /// How many redirect hops the send took. One hop is the ordinary case.
    var hopCount: Int {
        (spans.compactMap(\.hop).max()).map { $0 + 1 } ?? 0
    }

    func spans(forHop hop: Int) -> [Span] {
        spans.filter { $0.hop == hop }
    }

    /// The app's own stages, in the order they ran.
    var appSpans: [Span] {
        spans.filter { $0.hop == nil }
    }

    // MARK: - Building

    mutating func add(_ kind: Kind, hop: Int? = nil, from start: Date, to end: Date, since origin: Date) {
        spans.append(
            Span(
                kind: kind,
                hop: hop,
                startMilliseconds: start.timeIntervalSince(origin) * 1000,
                durationMilliseconds: max(end.timeIntervalSince(start), 0) * 1000
            )
        )
    }

    /// The dates URLSession reports for one transaction -- one request actually
    /// put on the wire, so a redirect chain produces several.
    ///
    /// Mirrored into a plain struct rather than passing
    /// `URLSessionTaskTransactionMetrics` around, because that class cannot be
    /// constructed in a test: every case below -- a reused connection, a
    /// redirect, a connection that failed partway and left half its dates nil
    /// -- would otherwise be untestable.
    struct TransactionDates: Sendable, Equatable {
        var domainLookupStart: Date?
        var domainLookupEnd: Date?
        var connectStart: Date?
        var connectEnd: Date?
        var secureConnectionStart: Date?
        var secureConnectionEnd: Date?
        var requestStart: Date?
        var requestEnd: Date?
        var responseStart: Date?
        var responseEnd: Date?
        var isReusedConnection = false

        init() {}
    }

    /// Turns each transaction's dates into the phases the waterfall draws.
    ///
    /// A phase whose two dates are not both present is left out rather than
    /// drawn as zero: a reused connection genuinely has no DNS lookup, and a
    /// row claiming it took 0 ms would be a different and false statement.
    static func networkSpans(
        from transactions: [TransactionDates], since origin: Date
    ) -> (spans: [Span], reusedHops: Set<Int>) {
        var timeline = RequestTimeline()

        for (hop, dates) in transactions.enumerated() {
            if dates.isReusedConnection { timeline.reusedConnectionHops.insert(hop) }

            let phases: [(Kind, Date?, Date?)] = [
                (.dns, dates.domainLookupStart, dates.domainLookupEnd),
                (.connect, dates.connectStart, dates.connectEnd),
                (.tls, dates.secureConnectionStart, dates.secureConnectionEnd),
                (.request, dates.requestStart, dates.requestEnd),
                // The wait for the first byte begins when the request finished
                // going out, which is not a date of its own.
                (.waiting, dates.requestEnd, dates.responseStart),
                (.download, dates.responseStart, dates.responseEnd),
            ]

            for (kind, start, end) in phases {
                guard let start, let end else { continue }
                timeline.add(kind, hop: hop, from: start, to: end, since: origin)
            }
        }

        return (timeline.spans, timeline.reusedConnectionHops)
    }
}
