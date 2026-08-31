import SwiftUI

/// The result of the most recent send: status, timing, and size, plus the body
/// and headers, and a script strip when a post-response script ran. The body
/// view has JSON highlighting and a find bar.
struct ResponsePanelView: View {
    let entry: HistoryEntry?
    let isSending: Bool

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

    /// Long lines run off to the side rather than wrapping, so one line of the
    /// response is always one row in the gutter.
    @State private var wrapsLines = false

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
            scriptStrip

            if isSearching { searchBar }

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

                Spacer()
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
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Sending…").foregroundStyle(.secondary)
            }
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
                    Text(measurements(for: response))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: focusSearchField) {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("f", modifiers: .command)
                    .help("Find in response body")
                }
            }
        } else {
            Text("No request sent yet.").foregroundStyle(.secondary)
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

    private var searchBar: some View {
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
                isSearching = false
                searchTerm = ""
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
        .onAppear { isSearchFieldFocused = true }
    }

    /// Command-F opens the bar and puts the caret in it -- and does the same
    /// when it is already open, which is what a reader who has scrolled away
    /// from the field expects.
    private func focusSearchField() {
        isSearching = true
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
        currentMatch = 0
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
    private func toggleFold(at line: Int) {
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
    private var gutter: LineNumberRuler.Source? {
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
