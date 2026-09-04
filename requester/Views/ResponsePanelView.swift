import SwiftUI

/// The result of the most recent send: status, timing, and size, plus the body
/// and headers, and a script strip when a post-response script ran. The body
/// view has JSON highlighting and a find bar.
struct ResponsePanelView: View {
    let entry: HistoryEntry?
    let isSending: Bool

    /// The stage the in-flight send is in, and when it began -- what the status
    /// line names and counts while `isSending`. Both nil when nothing is in
    /// flight, which is every other moment.
    var liveStage: RequestTimeline.Kind?
    var sendStartedAt: Date?

    /// Whether the timing breakdown under the status line is open. Off by
    /// default: the one-line summary answers the usual question, and the
    /// waterfall is for when it does not.
    @State private var isTimelineExpanded = false

    @State private var selectedTab: Tab = .body
    @State private var searchTerm = ""
    @State private var isSearching = false
    @State private var format: BodyFormat = .pretty

    /// Where the search term occurs in the body. Finding them means scanning
    /// the whole thing, so it is state settled after a pause in typing rather
    /// than a property recomputed on every redraw.
    @State private var matches: [NSRange] = []

    /// Which of `matches` Enter last landed on.
    @State private var currentMatch = 0

    /// Where the reader was, in the unfolded body, when a fold was toggled.
    ///
    /// Folding rewrites every offset below it, so `matches` has to be scanned
    /// again -- and the scan cannot know which of the new ranges is the one the
    /// reader was standing on. This carries that across, and is cleared as soon
    /// as it has been used. Nil for a scan caused by anything else: a new
    /// response, or a Pretty/Raw switch, is a different body, and starting at
    /// its first match is right.
    @State private var matchAnchor: FoldableText.Projection.SourcePosition?

    @FocusState private var isSearchFieldFocused: Bool

    /// The body indexed for display: formatted text, where its lines start, and
    /// which of them open a block. Built when the response or the format
    /// changes rather than on every redraw, because it walks the whole body.
    @State private var document = FoldableText.plain("")

    /// Source lines whose blocks are collapsed.
    @State private var folded: Set<Int> = []

    /// `document` with `folded` applied -- what the text view actually holds,
    /// and what the gutter numbers from.
    @State private var projection = FoldableText.plain("").projected(folding: [])

    /// Long lines wrap, so a response is readable without scrolling sideways
    /// for it. A wrapped source line is then several rows tall and its number
    /// sits on the first of them; the toggle turns that off for reading a body
    /// where one line to one row matters.
    @State private var wrapsLines = true

    private enum BodyFormat: String, CaseIterable, Identifiable {
        case pretty = "Pretty"
        case raw = "Raw"

        var id: String { rawValue }
    }

    private enum Tab: String, CaseIterable, Identifiable {
        case body = "Body"
        case headers = "Headers"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusLine
            timelineBreakdown
            scriptStrip

            HStack(spacing: 8) {
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if selectedTab == .body, JSONFormatter.looksLikeJSON(bodyText) {
                    Picker("", selection: $format) {
                        ForEach(BodyFormat.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                if selectedTab == .body {
                    Toggle(isOn: $wrapsLines) {
                        Image(systemName: "text.append")
                    }
                    .toggleStyle(.button)
                    .disabled(!canUnwrap)
                    .help(
                        canUnwrap
                            ? "Wrap long lines"
                            : "This body has a line too long to show unwrapped"
                    )
                }

                Spacer(minLength: 8)
                // Only once there is a body to look through, as before -- the
                // control used to sit on the status line, which had a response
                // by definition.
                if entry?.response != nil { searchControl }
            }

            content
        }
        .padding(12)
        .onChange(of: entry?.id) { searchTerm = "" }
        .task(id: MatchQuery(term: searchTerm, body: projection.text)) { await findMatches() }
        .onChange(of: bodyText, initial: true) { reformat() }
        .onChange(of: format) { reformat() }
    }

    // MARK: - Header

    @ViewBuilder
    private var statusLine: some View {
        if isSending {
            liveLine
        } else if let entry {
            if let error = entry.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Palette.invalid)
            } else if let response = entry.response {
                HStack(spacing: 10) {
                    Text("\(response.statusCode) \(response.reasonPhrase)")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(response.statusColor)

                    // The measurements are the disclosure control: the summary
                    // is what you read first, and the breakdown is the same
                    // number taken apart.
                    if entry.timeline?.isEmpty == false {
                        Button {
                            withAnimation(.snappy) { isTimelineExpanded.toggle() }
                        } label: {
                            HStack(spacing: 3) {
                                Text(measurements(for: response))
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .rotationEffect(.degrees(isTimelineExpanded ? 90 : 0))
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("Where this request's time went")
                    } else {
                        Text(measurements(for: response))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        } else {
            Text("No request sent yet.").foregroundStyle(.secondary)
        }
    }

    /// What is showing while a send is in flight: which stage is running, and
    /// how long it has been going.
    ///
    /// Coarser than the breakdown that replaces it, and unavoidably so -- the
    /// network phases inside "Sending" are reported by URLSession only once the
    /// task has finished, so nothing here could name them while they happen.
    private var liveLine: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(liveStage?.runningLabel ?? "Sending…").foregroundStyle(.secondary)

            if let sendStartedAt {
                // The clock is driven by the view rather than by a timer this
                // view owns, so nothing has to be started, stopped, or cleaned
                // up when the send ends.
                TimelineView(.periodic(from: sendStartedAt, by: 0.1)) { context in
                    Text(elapsed(from: sendStartedAt, to: context.date))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(now.timeIntervalSince(start), 0)
        return "\(seconds.formatted(.number.precision(.fractionLength(1))))s"
    }

    // MARK: - Timeline

    /// The waterfall: one block of rows per redirect hop, then the app's own
    /// stages. Every bar is laid out against the same total, so their widths
    /// are comparable across the whole send.
    @ViewBuilder
    private var timelineBreakdown: some View {
        if isTimelineExpanded, let timeline = entry?.timeline, !timeline.isEmpty {
            let scale = max(timeline.totalMilliseconds, 1)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<timeline.hopCount, id: \.self) { hop in
                    VStack(alignment: .leading, spacing: 2) {
                        if timeline.hopCount > 1 || timeline.reusedConnectionHops.contains(hop) {
                            Text(hopLabel(hop, in: timeline))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(timeline.spans(forHop: hop)) { span in
                            timelineRow(span, scale: scale)
                        }
                    }
                }

                if !timeline.appSpans.isEmpty {
                    Divider()
                    ForEach(timeline.appSpans) { span in
                        timelineRow(span, scale: scale)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func hopLabel(_ hop: Int, in timeline: RequestTimeline) -> String {
        var label = timeline.hopCount > 1 ? "hop \(hop + 1)" : "network"
        if timeline.reusedConnectionHops.contains(hop) { label += " · connection reused" }
        return label
    }

    /// One bar, positioned and sized against the send's total duration.
    private func timelineRow(_ span: RequestTimeline.Span, scale: Double) -> some View {
        HStack(spacing: 8) {
            Text(span.kind.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
                .padding(.leading, span.kind.isNestedInPrevious ? 10 : 0)

            GeometryReader { geometry in
                let width = geometry.size.width
                RoundedRectangle(cornerRadius: 2)
                    .fill(span.kind.isNetwork ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    // A span too short to see still gets a sliver, so a row is
                    // never an empty line the reader has to interpret.
                    .frame(width: max(span.durationMilliseconds / scale * width, 2))
                    .offset(x: span.startMilliseconds / scale * width)
            }
            .frame(height: 8)

            Text("\(span.durationMilliseconds.formatted(.number.precision(.fractionLength(0)))) ms")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .trailing)
        }
    }

    private func measurements(for response: ResponseRecord) -> String {
        var parts = [
            "\(response.elapsedMilliseconds.formatted(.number.precision(.fractionLength(0)))) ms",
            response.bodySizeBytes.formatted(.byteCount(style: .file)),
        ]
        if !response.httpVersion.isEmpty { parts.append(response.httpVersion) }
        if response.bodyTruncated { parts.append("truncated") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var scriptStrip: some View {
        if let result = entry?.scriptResult, result.ran {
            let written = result.variablesWritten.keys.sorted().joined(separator: ", ")
            Label {
                if result.succeeded {
                    Text("Script OK — variables set: \(written.isEmpty ? "none" : written)")
                } else {
                    Text("Script error: \(result.error ?? "unknown")")
                }
            } icon: {
                Image(
                    systemName: result.succeeded
                        ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
            }
            .font(.caption)
            .foregroundStyle(result.succeeded ? Palette.valid : Palette.invalid)
        }
    }

    /// Find-in-body, at the right-hand end of the controls row: a button until
    /// it is asked for, then the field in its place.
    ///
    /// Opening it grows the field leftwards rather than adding a row of its
    /// own, which is what keeps the body from jumping down the moment you go
    /// looking for something in it. The `Spacer` before this is what yields the
    /// width, so the growth reads as coming from the right edge.
    @ViewBuilder
    private var searchControl: some View {
        if isSearching {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search response body…", text: $searchTerm)
                    .textFieldStyle(.plain)
                    .focused($isSearchFieldFocused)
                    .onSubmit(advanceToNextMatch)
                if !matchSummary.isEmpty {
                    Text(matchSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    withAnimation(.snappy(duration: 0.2)) { isSearching = false }
                    searchTerm = ""
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 260)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
            // From the trailing edge, so it appears to come out of the button
            // it replaced rather than fading in over the row.
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .onAppear { isSearchFieldFocused = true }
        } else {
            Button(action: focusSearchField) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut("f", modifiers: .command)
            .help("Find in response body")
        }
    }

    /// Command-F opens the bar and puts the caret in it -- and does the same
    /// when it is already open, which is what a reader who has scrolled away
    /// from the field expects.
    private func focusSearchField() {
        withAnimation(.snappy(duration: 0.2)) { isSearching = true }
        isSearchFieldFocused = true
    }

    /// Enter walks the matches, wrapping round at the end.
    private func advanceToNextMatch() {
        guard !matches.isEmpty else { return }
        currentMatch = (currentMatch + 1) % matches.count
    }

    private var matchSummary: String {
        guard !searchTerm.isEmpty else { return "" }
        guard !matches.isEmpty else { return "No matches" }
        return "\(currentMatch + 1) of \(matches.count)"
    }

    /// The match to reveal, guarded because the search runs behind the typing
    /// and the list can be replaced between one redraw and the next.
    private var highlightedMatch: NSRange? {
        matches.indices.contains(currentMatch) ? matches[currentMatch] : nil
    }

    /// The term and the text it is counted in. Comparing two bodies is a
    /// buffer comparison, so using one as part of a task identity is cheap
    /// even when the response is megabytes long.
    private struct MatchQuery: Equatable {
        var term: String
        var body: String
    }

    /// Waits for typing to settle, then scans off the main actor. The
    /// highlighting in the text view does not go through here -- it is applied
    /// per visible line and is always current; this feeds the label and Enter.
    private func findMatches() async {
        guard !searchTerm.isEmpty else {
            matches = []
            currentMatch = 0
            // Folding with no search running leaves an anchor nothing consumes.
            // Dropped here, or the next search would open partway down the body
            // at whatever was under it at the time.
            matchAnchor = nil
            return
        }

        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }

        let term = searchTerm
        let body = projection.text
        let found = await Task.detached {
            let text = body as NSString
            return SyntaxHighlighter.matchRanges(
                of: term, in: text, range: NSRange(location: 0, length: text.length)
            )
        }.value

        guard !Task.isCancelled else { return }
        matches = found
        currentMatch = restoredMatchIndex(in: found)
        matchAnchor = nil
    }

    /// Which match to stand on after a rescan.
    ///
    /// Zero unless a fold put an anchor down, in which case it is the first
    /// match at or after where the reader was. "At or after" rather than
    /// nearest, because the anchor's own match is at exactly that offset when
    /// it is still on screen -- and when the fold swallowed it, the next match
    /// below is where reading would have continued.
    private func restoredMatchIndex(in found: [NSRange]) -> Int {
        guard let matchAnchor,
              let offset = projection.offset(ofSourcePosition: matchAnchor),
              let index = found.firstIndex(where: { $0.location >= offset })
        else { return 0 }
        return index
    }

    /// A minified response arrives as one enormous line, which is unreadable and
    /// also the worst case for text layout. Pretty is therefore the default.
    ///
    /// One pass produces the text, its line index and its fold points together.
    /// The raw view keeps the index -- the wrap control reads the longest line
    /// off it -- but does not draw a gutter from it.
    private func reformat() {
        // The Raw / Pretty picker is only offered for a JSON body, so a body
        // that is not JSON has nothing on screen to switch back with -- Raw
        // left over from the previous response would be stuck.
        if !looksLikeJSON { format = .pretty }
        document = isPretty ? FoldableText.json(bodyText) : FoldableText.plain(bodyText)
        folded = []
        reproject()
    }

    /// Whether the body is being shown formatted. Raw means the bytes as they
    /// arrived: no numbering, no colouring, nothing folded.
    private var isPretty: Bool { format == .pretty && looksLikeJSON }

    private func reproject() {
        projection = document.projected(folding: folded)
    }

    /// Collapses or expands the block opening on `line`.
    ///
    /// The reader's place in the search is noted first, in terms of the
    /// unfolded body, so the rescan that follows can put them back on the match
    /// they were on rather than at the top.
    private func toggleFold(at line: Int) {
        // Only the first of a run of folds anchors. The scan is debounced, so a
        // second click lands while `matches` still describe the projection from
        // before the first one -- reading a position off them then would place
        // the anchor on the wrong line. The first click's anchor was taken
        // while the two agreed, and is the one worth keeping.
        if matchAnchor == nil {
            matchAnchor = highlightedMatch.flatMap {
                projection.sourcePosition(ofOffset: $0.location)
            }
        }
        if folded.contains(line) { folded.remove(line) } else { folded.insert(line) }
        reproject()
    }

    /// A single enormous line -- a minified body in the raw view -- is wrapped
    /// whatever the toggle says, so the toggle is disabled rather than ignored.
    private var canUnwrap: Bool {
        CodeEditor.canUnwrap(longestLineLength: projection.longestLineLength)
    }

    /// The gutter, and `nil` for the raw view -- which is the whole point of
    /// asking for raw: the body as it arrived, unnumbered and uncoloured.
    private var gutter: LineNumberGutter.Source? {
        guard isPretty else { return nil }
        return .init(
            document: document,
            projection: projection,
            folded: folded,
            // Nothing in an unformatted body opens a block.
            showsFoldControls: true
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .body:
            CodeEditor(
                text: .constant(projection.text),
                options: .init(json: isPretty),
                isEditable: false,
                searchTerm: searchTerm,
                indentsAutomatically: false,
                gutter: gutter,
                onToggleFold: toggleFold,
                wrapsLines: wrapsLines,
                longestLineLength: projection.longestLineLength,
                highlightedMatch: highlightedMatch
            )
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))

        case .headers:
            CodeEditor(text: .constant(headersText), isEditable: false, indentsAutomatically: false)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var bodyText: String { entry?.response?.bodyText ?? "" }

    private var headersText: String {
        (entry?.response?.headers ?? []).map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    /// Highlight as JSON based on the content, not the declared content type --
    /// plenty of APIs return JSON as `text/plain`.
    private var looksLikeJSON: Bool { JSONFormatter.looksLikeJSON(bodyText) }
}
