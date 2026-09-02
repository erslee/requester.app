import Foundation
import Testing
@testable import requester

/// The network half of a timeline is built from dates URLSession only fills in
/// sometimes: a reused connection has no DNS or handshake, a redirect produces
/// a set per hop, and a connection that failed partway leaves the rest nil.
/// Those are the cases worth testing, and the reason the arithmetic is a pure
/// function over plain dates rather than over `URLSessionTaskTransactionMetrics`.
struct RequestTimelineTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func date(_ offsetMilliseconds: Double) -> Date {
        origin.addingTimeInterval(offsetMilliseconds / 1000)
    }

    /// Milliseconds come from `TimeInterval` arithmetic, so they land a
    /// fraction of a microsecond either side of the round number that went in.
    /// Nothing here cares below that.
    private func isClose(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 0.001
    }

    /// A complete, first-time connection: every phase present, in order.
    private func fullTransaction() -> RequestTimeline.TransactionDates {
        var dates = RequestTimeline.TransactionDates()
        dates.domainLookupStart = date(0)
        dates.domainLookupEnd = date(4)
        dates.connectStart = date(4)
        dates.connectEnd = date(15)
        dates.secureConnectionStart = date(7)
        dates.secureConnectionEnd = date(15)
        dates.requestStart = date(15)
        dates.requestEnd = date(16)
        dates.responseStart = date(105)
        dates.responseEnd = date(111)
        return dates
    }

    @Test func buildsEveryPhaseOfAFreshConnection() {
        // Act
        let (spans, reused) = RequestTimeline.networkSpans(
            from: [fullTransaction()], since: origin
        )

        // Assert -- six rows, in wire order
        #expect(spans.map(\.kind) == [.dns, .connect, .tls, .request, .waiting, .download])
        #expect(reused.isEmpty)
        #expect(spans.allSatisfy { $0.hop == 0 })
    }

    @Test func measuresEachPhaseFromTheSendsStart() {
        // Act
        let (spans, _) = RequestTimeline.networkSpans(from: [fullTransaction()], since: origin)
        let byKind = Dictionary(uniqueKeysWithValues: spans.map { ($0.kind, $0) })

        // Assert -- durations
        #expect(isClose(byKind[.dns]?.durationMilliseconds, 4))
        #expect(isClose(byKind[.connect]?.durationMilliseconds, 11))
        #expect(isClose(byKind[.tls]?.durationMilliseconds, 8))
        // The wait for the first byte runs from the request going out, which
        // URLSession gives no date of its own for.
        #expect(isClose(byKind[.waiting]?.startMilliseconds, 16))
        #expect(isClose(byKind[.waiting]?.durationMilliseconds, 89))
        #expect(isClose(byKind[.download]?.durationMilliseconds, 6))
    }

    /// TLS sits inside connect rather than after it, so the view has to indent
    /// it instead of laying it out as the next sibling.
    @Test func nestsTLSInsideConnect() {
        // Act
        let (spans, _) = RequestTimeline.networkSpans(from: [fullTransaction()], since: origin)
        let byKind = Dictionary(uniqueKeysWithValues: spans.map { ($0.kind, $0) })

        // Assert
        #expect(RequestTimeline.Kind.tls.isNestedInPrevious)
        let connect = try! #require(byKind[.connect])
        let tls = try! #require(byKind[.tls])
        #expect(tls.startMilliseconds >= connect.startMilliseconds)
        #expect(tls.endMilliseconds <= connect.endMilliseconds)
    }

    /// A connection already open has no lookup and no handshake. Those rows are
    /// absent rather than zero -- a 0 ms DNS row would be a false statement.
    @Test func omitsSetupPhasesOnAReusedConnection() {
        // Arrange
        var dates = RequestTimeline.TransactionDates()
        dates.isReusedConnection = true
        dates.requestStart = date(0)
        dates.requestEnd = date(1)
        dates.responseStart = date(40)
        dates.responseEnd = date(42)

        // Act
        let (spans, reused) = RequestTimeline.networkSpans(from: [dates], since: origin)

        // Assert
        #expect(spans.map(\.kind) == [.request, .waiting, .download])
        #expect(reused == [0])
    }

    @Test func numbersEachRedirectHopSeparately() {
        // Arrange -- a redirect: two transactions, the second reusing nothing
        var second = fullTransaction()
        second.domainLookupStart = date(120)
        second.domainLookupEnd = date(122)
        second.connectStart = date(122)
        second.connectEnd = date(130)
        second.secureConnectionStart = date(124)
        second.secureConnectionEnd = date(130)
        second.requestStart = date(130)
        second.requestEnd = date(131)
        second.responseStart = date(160)
        second.responseEnd = date(165)

        // Act
        let (spans, _) = RequestTimeline.networkSpans(
            from: [fullTransaction(), second], since: origin
        )

        // Assert
        var timeline = RequestTimeline()
        timeline.spans = spans
        #expect(timeline.hopCount == 2)
        #expect(timeline.spans(forHop: 0).count == 6)
        #expect(timeline.spans(forHop: 1).count == 6)
        #expect(isClose(timeline.spans(forHop: 1).first?.startMilliseconds, 120))
    }

    /// A send that failed while connecting leaves everything after the failure
    /// nil. What is known should still be reported.
    @Test func keepsWhatIsKnownWhenTheRestIsMissing() {
        // Arrange
        var dates = RequestTimeline.TransactionDates()
        dates.domainLookupStart = date(0)
        dates.domainLookupEnd = date(3)
        dates.connectStart = date(3)

        // Act
        let (spans, _) = RequestTimeline.networkSpans(from: [dates], since: origin)

        // Assert -- the lookup happened; the connect never finished
        #expect(spans.map(\.kind) == [.dns])
    }

    @Test func reportsNothingForATransactionWithNoDates() {
        // Act
        let (spans, reused) = RequestTimeline.networkSpans(
            from: [RequestTimeline.TransactionDates()], since: origin
        )

        // Assert
        #expect(spans.isEmpty)
        #expect(reused.isEmpty)
    }

    // MARK: - App stages

    @Test func recordsAppStagesRelativeToTheSendsStart() {
        // Arrange
        var timeline = RequestTimeline()

        // Act
        timeline.add(.prepare, from: date(0), to: date(3), since: origin)
        timeline.add(.send, from: date(3), to: date(115), since: origin)

        // Assert -- app stages carry no hop, so they survive a redirect chain
        #expect(timeline.appSpans.map(\.kind) == [.prepare, .send])
        #expect(isClose(timeline.appSpans.first?.startMilliseconds, 0))
        #expect(isClose(timeline.appSpans.first?.durationMilliseconds, 3))
        #expect(isClose(timeline.appSpans.last?.startMilliseconds, 3))
        #expect(isClose(timeline.appSpans.last?.durationMilliseconds, 112))
    }

    /// Clocks are not guaranteed monotonic; a negative span would draw as a bar
    /// running backwards.
    @Test func neverProducesANegativeDuration() {
        // Arrange
        var timeline = RequestTimeline()

        // Act
        timeline.add(.script, from: date(10), to: date(4), since: origin)

        // Assert
        #expect(timeline.spans.first?.durationMilliseconds == 0)
    }

    // MARK: - One origin

    /// The two halves of a timeline are built at different moments and from
    /// different sources -- the app stages as they run, the network phases from
    /// metrics handed over at the end -- but they are drawn on one axis, so
    /// they must be measured from one origin.
    ///
    /// They were not. The executor timed the network from the instant it began
    /// sending, while the pipeline timed its stages from the instant the send
    /// was requested, and the gap between the two was however long preparing
    /// the request took. Every network bar drew that far to the left, outside
    /// the `send` stage that contains it. It looked right until a screenshot
    /// showed DNS starting before the send it happens inside.
    @Test func networkPhasesFallInsideTheSendStageTheyBelongTo() throws {
        // Arrange -- the pipeline's shape: prepare, then a send holding the
        // network phases, measured the way `HistoryService` measures them.
        let origin = self.origin
        var timeline = RequestTimeline()
        timeline.add(.prepare, from: date(0), to: date(4), since: origin)
        timeline.add(.send, from: date(4), to: date(115), since: origin)

        var dates = RequestTimeline.TransactionDates()
        dates.domainLookupStart = date(4)
        dates.domainLookupEnd = date(8)
        dates.requestStart = date(8)
        dates.requestEnd = date(9)
        dates.responseStart = date(110)
        dates.responseEnd = date(115)

        // Act -- the same origin the app stages used, which is the whole point
        let (networkSpans, _) = RequestTimeline.networkSpans(from: [dates], since: origin)
        timeline.spans += networkSpans

        // Assert -- every network phase sits within the send that contains it
        let send = try #require(timeline.appSpans.first { $0.kind == .send })
        for span in timeline.spans where span.kind.isNetwork {
            #expect(span.startMilliseconds >= send.startMilliseconds)
            #expect(span.endMilliseconds <= send.endMilliseconds)
        }

        // Assert -- and none of them starts at zero, where `prepare` is
        #expect(timeline.spans.filter(\.kind.isNetwork).allSatisfy { $0.startMilliseconds > 0 })
    }

    // MARK: - Storage

    /// Timelines are written into history, so they have to survive the round
    /// trip the entries take.
    @Test func survivesAJSONRoundTrip() throws {
        // Arrange
        var timeline = RequestTimeline()
        timeline.add(.prepare, from: date(0), to: date(3), since: origin)
        let (spans, reused) = RequestTimeline.networkSpans(
            from: [fullTransaction()], since: origin
        )
        timeline.spans += spans
        timeline.reusedConnectionHops = reused
        timeline.totalMilliseconds = 140

        // Act
        let data = try JSONCoding.compactEncoder.encode(timeline)
        let decoded = try JSONCoding.decoder.decode(RequestTimeline.self, from: data)

        // Assert
        #expect(decoded == timeline)
    }
}
