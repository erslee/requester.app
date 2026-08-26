import SwiftUI

/// Shown when a project rather than a request is selected: its name, plus the
/// project's variables, usable as `{{name}}` in any request inside it.
struct ProjectDetailView: View {
    @Bindable var model: AppModel
    let projectID: String

    @State private var name = ""
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Project name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold))
                .onSubmit(commitName)

            VStack(alignment: .leading, spacing: 8) {
                Text("VARIABLES — use as {{name}} in any request in this project")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                VariablesTableView(model: model, projectID: projectID)
            }
        }
        .padding(20)
        .task(id: projectID) { await load() }
    }

    private func load() async {
        name = model.projectList.first { $0.id == projectID }?.name ?? ""
        await model.reloadVariables(projectID: projectID)
    }

    /// A blank name reverts rather than being accepted, so a project can never
    /// become an unlabelled row.
    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let current = model.projectList.first { $0.id == projectID }?.name ?? ""
        guard !trimmed.isEmpty else {
            name = current
            return
        }
        guard trimmed != current else { return }
        Task { await model.renameProject(projectID, to: trimmed) }
    }
}

/// The project's variables. A key is fixed once the variable exists -- delete
/// and recreate rather than rename -- so only the value is editable. Editing a
/// script-written value simply makes it manual from then on.
struct VariablesTableView: View {
    let model: AppModel
    let projectID: String

    @State private var newKey = ""
    @State private var newValue = ""
    @State private var editedValues: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.variables(forProject: projectID)) { variable in
                        row(for: variable)
                        Divider().opacity(0.4)
                    }
                    newRow
                }
            }
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    // Compressible columns, for the same reason as the key/value table: fixed
    // widths that outgrow the detail column would clip the table.
    private enum Column {
        static let keyMin: CGFloat = 110
        static let keyMax: CGFloat = 200
        static let valueMin: CGFloat = 140
        static let source: CGFloat = 64
        static let updatedMin: CGFloat = 100
        static let remove: CGFloat = 20
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Key")
                .frame(minWidth: Column.keyMin, maxWidth: Column.keyMax, alignment: .leading)
            Text("Value")
                .frame(minWidth: Column.valueMin, alignment: .leading)
            Text("Source")
                .frame(width: Column.source, alignment: .leading)
            Text("Updated")
                .frame(minWidth: Column.updatedMin, alignment: .leading)
            Spacer(minLength: Column.remove)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func row(for variable: Variable) -> some View {
        HStack(spacing: 8) {
            Text(variable.key)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: Column.keyMin, maxWidth: Column.keyMax, alignment: .leading)

            TextField(
                "Value",
                text: .init(
                    get: { editedValues[variable.key] ?? variable.value },
                    set: { editedValues[variable.key] = $0 }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(.body, design: .monospaced))
            .frame(minWidth: Column.valueMin)
            .onSubmit { commit(key: variable.key) }

            Text(variable.source.rawValue)
                .font(.caption)
                .foregroundStyle(variable.source == .script ? Palette.jsonKey : .secondary)
                .frame(width: Column.source, alignment: .leading)

            Text(variable.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: Column.updatedMin, alignment: .leading)

            Button {
                Task { await model.deleteVariable(projectID: projectID, key: variable.key) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .frame(width: Column.remove)
            .help("Delete this variable")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// New variables need both a key and a value before they are created --
    /// otherwise typing just the key would save a half-formed variable.
    private var newRow: some View {
        HStack(spacing: 8) {
            TextField("New key", text: $newKey)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: Column.keyMin, maxWidth: Column.keyMax)
                .onSubmit(addNew)

            TextField("New value", text: $newValue)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: Column.valueMin)
                .onSubmit(addNew)

            Button("Add", action: addNew)
                .buttonStyle(.link)
                .disabled(
                    newKey.trimmingCharacters(in: .whitespaces).isEmpty || newValue.isEmpty
                )

            Spacer(minLength: Column.remove)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func commit(key: String) {
        guard let value = editedValues.removeValue(forKey: key) else { return }
        Task { await model.setVariable(projectID: projectID, key: key, value: value) }
    }

    private func addNew() {
        let key = newKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !newValue.isEmpty else { return }
        let value = newValue
        newKey = ""
        newValue = ""
        Task { await model.setVariable(projectID: projectID, key: key, value: value) }
    }
}
