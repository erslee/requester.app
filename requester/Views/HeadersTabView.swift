import SwiftUI

/// The request's Headers tab: the request's own headers, and below them what
/// it inherits from the project.
///
/// The inherited rows are listed rather than merged into the table above, and
/// are read-only: they belong to the project, so editing one here would change
/// every other request in it. An overridden one stays listed, struck through,
/// so it reads as "the project sets this, and this request is deliberately not
/// using its value" rather than quietly disappearing.
struct HeadersTabView: View {
    @Binding var headers: [KeyValueItem]
    var globalHeaders: [KeyValueItem] = []
    var knownVariableNames: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            KeyValueTableView(items: $headers, knownVariableNames: knownVariableNames)

            if !inheritable.isEmpty { inheritedSection }
        }
    }

    /// The project rows that would be sent at all -- a switched-off global
    /// header reaches no request, so listing it here would only be noise.
    private var inheritable: [KeyValueItem] {
        globalHeaders.filter { $0.enabled && !$0.key.isEmpty }
    }

    private var inheritedSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("INHERITED FROM PROJECT")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(inheritable) { header in
                inheritedRow(header, isOverridden: HeaderMerge.isOverridden(header, by: headers))
            }
        }
        .padding(.horizontal, 8)
    }

    private func inheritedRow(_ header: KeyValueItem, isOverridden: Bool) -> some View {
        HStack(spacing: 6) {
            Text("\(header.key): \(header.value)")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(isOverridden ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .strikethrough(isOverridden)
                .lineLimit(1)
                .truncationMode(.middle)

            if isOverridden {
                Text("overridden below")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
