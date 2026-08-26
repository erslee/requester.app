import SwiftUI

/// Read-only view of one history entry: everything sent, everything received,
/// and what the script did. The full body is fetched from its blob file when
/// the inline copy was truncated.
struct HistoryDetailView: View {
    let entry: HistoryEntry
    let history: HistoryModel

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Tab = .response
    @State private var fullBody: String?

    private enum Tab: String, CaseIterable, Identifiable {
        case request = "Request"
        case response = "Response"
        case script = "Script"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            CodeEditor(
                text: .constant(text(for: selectedTab)),
                options: .init(json: selectedTab == .response),
                isEditable: false,
                indentsAutomatically: false
            )
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                if entry.response?.bodyTruncated == true {
                    Label(
                        fullBody == nil ? "Loading the full body…" : "Showing the full body",
                        systemImage: "arrow.down.doc"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 560)
        .task {
            guard entry.response?.bodyTruncated == true else { return }
            fullBody = await history.fullBody(for: entry)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.requestSnapshot.method.rawValue)
                    .font(.headline)
                    .foregroundStyle(entry.requestSnapshot.method.color)
                Text(entry.resolvedURL)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Text(entry.sentAt.formatted(date: .abbreviated, time: .standard))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func text(for tab: Tab) -> String {
        switch tab {
        case .request:
            let headers = entry.requestHeadersSent
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
            return "Headers:\n\(headers)\n\nBody:\n\(entry.requestBodySent)"

        case .response:
            guard let response = entry.response else {
                return "Error: \(entry.error ?? "unknown")"
            }
            let headers = response.headers
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
            let body = JSONFormatter.prettyPrintedIfJSON(fullBody ?? response.bodyText)
            let note = response.bodyTruncated && fullBody == nil
                ? "\n\n[Truncated — full body at \(response.bodyBlobPath ?? "?")]"
                : ""
            return """
                Status: \(response.statusCode) \(response.reasonPhrase)
                Time: \(response.elapsedMilliseconds.formatted(.number.precision(.fractionLength(0)))) ms   \
                Size: \(response.bodySizeBytes.formatted(.byteCount(style: .file)))

                Headers:
                \(headers)

                Body:
                \(body)\(note)
                """

        case .script:
            guard let result = entry.scriptResult, result.ran else {
                return "No script ran for this request."
            }
            let status = result.succeeded ? "Succeeded" : "Failed: \(result.error ?? "unknown")"
            let written = result.variablesWritten.isEmpty
                ? "(none)"
                : result.variablesWritten
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key) = \($0.value)" }
                    .joined(separator: "\n")
            return """
                Status: \(status)

                Variables written:
                \(written)

                Output:
                \(result.output)
                """
        }
    }
}
