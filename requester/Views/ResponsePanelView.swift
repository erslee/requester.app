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

    /// The body as shown. Reformatting a large body is not cheap, so it is done
    /// when the response or the format changes rather than on every redraw.
    @State private var displayedBody = ""

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

                Spacer()
            }

            content
        }
        .padding(12)
        .onChange(of: entry?.id) { searchTerm = "" }
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
                    Button {
                        isSearching.toggle()
                    } label: {
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
            if !searchTerm.isEmpty {
                Text(matchSummary).font(.caption).foregroundStyle(.secondary)
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
    }

    private var matchSummary: String {
        let count = displayedBody.ranges(of: searchTerm).count
        return count == 1 ? "1 match" : "\(count) matches"
    }

    /// A minified response arrives as one enormous line, which is unreadable and
    /// also the worst case for text layout. Pretty is therefore the default.
    private func reformat() {
        displayedBody = format == .pretty
            ? JSONFormatter.prettyPrintedIfJSON(bodyText)
            : bodyText
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .body:
            CodeEditor(
                text: .constant(displayedBody),
                options: .init(json: looksLikeJSON),
                isEditable: false,
                searchTerm: searchTerm,
                indentsAutomatically: false
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
