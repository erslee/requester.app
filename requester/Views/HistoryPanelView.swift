import AppKit
import SwiftUI

/// History for the current scope -- every request in the project, or just the
/// selected one -- grouped by day, newest first. Selecting an entry previews it
/// in the editor and response panel; the info button opens the full record.
struct HistoryPanelView: View {
    @Bindable var model: AppModel
    @Bindable var history: HistoryModel

    @State private var detailEntry: HistoryEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(history.scopeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            filters

            if history.entries.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(
                        history.searchText.isEmpty
                            ? "Sends will appear here."
                            : "Nothing matches this filter."
                    )
                )
            } else {
                List {
                    ForEach(history.groups) { group in
                        Section(group.label) {
                            ForEach(group.entries) { entry in
                                row(for: entry)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(10)
        .sheet(item: $detailEntry) { entry in
            HistoryDetailView(entry: entry, history: history)
        }
    }

    private var filters: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history…", text: $history.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 6) {
                Picker("", selection: $history.methodFilter) {
                    Text("Any method").tag(HTTPMethod?.none)
                    ForEach(HTTPMethod.allCases) { method in
                        Text(method.rawValue).tag(HTTPMethod?.some(method))
                    }
                }
                .labelsHidden()

                TextField("Status", text: $history.statusCodeFilter)
                    .frame(width: 64)
            }
            .controlSize(.small)
        }
        .onChange(of: history.searchText) { Task { await history.refresh() } }
        .onChange(of: history.methodFilter) { Task { await history.refresh() } }
        .onChange(of: history.statusCodeFilter) { Task { await history.refresh() } }
    }

    private func row(for entry: HistoryEntry) -> some View {
        let isActive = history.selectedEntryID == entry.id

        return HStack(spacing: 6) {
            Text(entry.requestSnapshot.method.rawValue)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(entry.requestSnapshot.method.color)
                .frame(width: 52, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.resolvedURL)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.sentAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            if let response = entry.response {
                Text("\(response.statusCode)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(response.statusColor)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.invalid)
            }

            Button {
                detailEntry = entry
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Show the full record")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        )
        .contentShape(.rect)
        .onTapGesture { model.open(historyEntry: entry) }
        .contextMenu {
            Button("Open in Editor") { model.open(historyEntry: entry) }
            Button("Show Full Record…") { detailEntry = entry }
            Divider()
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.resolvedURL, forType: .string)
            }
        }
    }
}
