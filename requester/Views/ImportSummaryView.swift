import SwiftUI

/// What an import brought in, and what it could not.
///
/// Shown rather than logged: a collection that half-imported in silence is worse
/// than one that says which requests need attention.
struct ImportSummaryView: View {
    let summary: AppModel.ImportSummary

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Imported “\(summary.collectionName)”", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Palette.valid)
                Text(counts)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !summary.scriptsNeedingReview.isEmpty {
                section(
                    title: "Scripts to review",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: Palette.jsonNumber,
                    note: """
                        These still call Postman's `pm` API, which has no \
                        equivalent here. The parts that read the response and \
                        write variables were translated; the rest needs editing.
                        """,
                    rows: summary.scriptsNeedingReview
                )
            }

            if !summary.warnings.isEmpty {
                section(
                    title: "Not imported",
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
        .frame(minWidth: 460, minHeight: 260)
    }

    private var counts: String {
        let requests = "\(summary.requestCount) request\(summary.requestCount == 1 ? "" : "s")"
        guard summary.variableCount > 0 else { return requests }
        let variables =
            "\(summary.variableCount) variable\(summary.variableCount == 1 ? "" : "s")"
        return "\(requests) and \(variables)"
    }

    private func section(
        title: String,
        systemImage: String,
        tint: Color,
        note: String?,
        rows: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(rows, id: \.self) { row in
                        Text("• \(row)")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 140)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
