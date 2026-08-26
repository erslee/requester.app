import SwiftUI

/// What a sync changed.
///
/// Shown every time rather than only when something changed: pressing Update
/// and getting no feedback at all reads as a failure, so "nothing changed" is
/// itself worth saying.
struct SpecSyncSummaryView: View {
    let summary: SpecSyncService.Summary

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label(headline, systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Palette.valid)

                if summary.hasChanges {
                    HStack(spacing: 14) {
                        count(summary.added, "added", tint: Palette.valid)
                        count(summary.updated, "updated", tint: Palette.jsonKey)
                        count(summary.restored, "back", tint: Palette.jsonKeyword)
                        count(summary.removed, "removed", tint: Palette.invalid)
                    }
                    .font(.callout)
                } else {
                    Text("Nothing changed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if summary.removed > 0 {
                SummarySection(
                    title: "Removed endpoints are kept",
                    systemImage: "archivebox.fill",
                    tint: Palette.invalid,
                    note: """
                        \(summary.removed) endpoint\(summary.removed == 1 ? " is" : "s are") no \
                        longer in the document. \(summary.removed == 1 ? "It is" : "They are") \
                        marked in the sidebar but still open, still editable, and still hold \
                        their history — nothing was deleted.
                        """,
                    rows: []
                )
            }

            if !summary.warnings.isEmpty {
                SummarySection(
                    title: "Worth knowing",
                    systemImage: "info.circle.fill",
                    tint: Palette.jsonKey,
                    note: nil,
                    rows: summary.warnings
                )
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 240)
    }

    private var headline: String {
        summary.isFirstImport ? "Imported “\(summary.title)”" : "Updated from “\(summary.title)”"
    }

    /// A zero is dropped rather than shown, so the row reads as what happened
    /// instead of a form with empty fields.
    @ViewBuilder
    private func count(_ value: Int, _ label: String, tint: Color) -> some View {
        if value > 0 {
            HStack(spacing: 4) {
                Text("\(value)").fontWeight(.semibold).foregroundStyle(tint)
                Text(label).foregroundStyle(.secondary)
            }
        }
    }
}
