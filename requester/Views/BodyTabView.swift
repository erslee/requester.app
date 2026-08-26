import SwiftUI

/// Body tab: a mode picker driving the matching editor.
struct BodyTabView: View {
    @Binding var draft: APIRequest
    var knownVariableNames: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("", selection: $draft.bodyMode) {
                    ForEach(BodyMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()

                if draft.bodyMode == .raw {
                    Picker("", selection: $draft.rawBodyType) {
                        ForEach(RawBodyType.allCases) { type in
                            Text(type.rawValue.uppercased()).tag(type)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
            }
            // GraphQL is POST-only, so switching to it pins the method.
            .onChange(of: draft.bodyMode) {
                if draft.bodyMode == .graphQL { draft.method = .post }
            }

            switch draft.bodyMode {
            case .none:
                ContentUnavailableView(
                    "No Body", systemImage: "doc",
                    description: Text("This request sends no body.")
                )

            case .raw:
                PlaceholderCodeEditor(
                    text: $draft.rawBody,
                    options: .init(
                        json: draft.rawBodyType == .json,
                        knownVariableNames: knownVariableNames
                    ),
                    placeholder: "Raw request body"
                )

            case .form:
                KeyValueTableView(
                    items: formFieldsBinding,
                    knownVariableNames: knownVariableNames,
                    showsDescription: false
                )

            case .graphQL:
                graphQLEditors
            }
        }
    }

    private var graphQLEditors: some View {
        ResizableSplit(
            axis: .vertical, minimumFirst: 120, minimumSecond: 100, initialFraction: 0.6
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text("QUERY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                PlaceholderCodeEditor(
                    text: graphQLBinding.query,
                    options: .init(graphQL: true, knownVariableNames: knownVariableNames),
                    placeholder: "query { ... }"
                )
            }
            .padding(.bottom, 6)
        } second: {
            VStack(alignment: .leading, spacing: 4) {
                Text("VARIABLES (JSON)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                PlaceholderCodeEditor(
                    text: graphQLBinding.variablesJSON,
                    options: .init(json: true, knownVariableNames: knownVariableNames),
                    placeholder: #"{"key": "value"}"#
                )
            }
            .padding(.top, 6)
        }
    }

    private var graphQLBinding: Binding<GraphQLBody> {
        .init(
            get: { draft.graphQLBody ?? GraphQLBody() },
            set: { draft.graphQLBody = $0 }
        )
    }

    /// Form fields are edited through the shared key/value table, so they are
    /// projected to `KeyValueItem` and back. File fields are preserved rather
    /// than shown, since the table has no file picker.
    private var formFieldsBinding: Binding<[KeyValueItem]> {
        .init(
            get: {
                draft.formFields
                    .filter { !$0.isFile }
                    .map { KeyValueItem(key: $0.key, value: $0.value, enabled: $0.enabled) }
            },
            set: { items in
                let fileFields = draft.formFields.filter(\.isFile)
                draft.formFields = fileFields + items.map {
                    FormField(key: $0.key, value: $0.value, enabled: $0.enabled)
                }
            }
        )
    }
}
