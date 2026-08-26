import SwiftUI

/// Reusable `[KeyValueItem]` editor, shared by the Params, Headers, and
/// Form-data tabs. A trailing blank row is always kept for adding entries, and
/// key/value cells holding a `{{variable}}` are tinted green when the name is
/// defined in the project and red when it is not.
struct KeyValueTableView: View {
    @Binding var items: [KeyValueItem]
    var knownVariableNames: Set<String> = []
    var showsDescription: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($items) { $item in
                        row(for: $item)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .onAppear { ensureTrailingBlankRow() }
        .onChange(of: items) { ensureTrailingBlankRow() }
    }

    // Columns that can compress: fixed widths summing past the detail
    // column's own minimum would clip the table in a narrow window.
    private enum Column {
        static let toggle: CGFloat = 24
        static let keyMin: CGFloat = 100
        static let keyMax: CGFloat = 220
        static let valueMin: CGFloat = 140
        static let descriptionMin: CGFloat = 90
        static let remove: CGFloat = 20
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("On")
                .frame(width: Column.toggle)
            Text("Key")
                .frame(minWidth: Column.keyMin, maxWidth: Column.keyMax, alignment: .leading)
            Text("Value")
                .frame(minWidth: Column.valueMin, alignment: .leading)
            if showsDescription {
                Text("Description")
                    .frame(minWidth: Column.descriptionMin, alignment: .leading)
            }
            Spacer(minLength: Column.remove)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func row(for item: Binding<KeyValueItem>) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: item.enabled)
                .labelsHidden()
                .frame(width: Column.toggle)
                .disabled(item.wrappedValue.isBlank)

            cell(text: item.key, prompt: "Key")
                .frame(minWidth: Column.keyMin, maxWidth: Column.keyMax)

            cell(text: item.value, prompt: "Value")
                .frame(minWidth: Column.valueMin)

            if showsDescription {
                TextField("Description", text: item.description)
                    .textFieldStyle(.plain)
                    .frame(minWidth: Column.descriptionMin)
            }

            Button {
                items.removeAll { $0.id == item.wrappedValue.id }
                ensureTrailingBlankRow()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .opacity(item.wrappedValue.isBlank ? 0 : 1)
            .disabled(item.wrappedValue.isBlank)
            .frame(width: Column.remove)
            .help("Remove this row")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func cell(text: Binding<String>, prompt: String) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .variableTint(text.wrappedValue, knownNames: knownVariableNames)
    }

    /// Keeps exactly one blank row at the end: typing in it turns it into a
    /// real entry and a fresh blank row appears below.
    private func ensureTrailingBlankRow() {
        if let last = items.last, last.isBlank {
            // Strip any extra blanks that editing left behind mid-list.
            let trailingBlanks = items.reversed().prefix { $0.isBlank }.count
            if trailingBlanks > 1 { items.removeLast(trailingBlanks - 1) }
            return
        }
        items.append(KeyValueItem())
    }
}
