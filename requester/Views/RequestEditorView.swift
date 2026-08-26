import SwiftUI

/// The request editor: name, method, URL, and the
/// Params / Headers / Body / Auth / Scripts tabs.
///
/// Pasting (or typing) a curl command into the URL field imports it in place
/// rather than being inserted literally.
struct RequestEditorView: View {
    @Bindable var model: AppModel
    @Bindable var editor: EditorModel

    @State private var selectedTab: Tab = .params
    @FocusState private var isNameFocused: Bool

    enum Tab: String, CaseIterable, Identifiable {
        case params = "Params"
        case headers = "Headers"
        case body = "Body"
        case auth = "Auth"
        case scripts = "Scripts"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 10) {
            if let draft = Binding($editor.draft) {
                nameField(draft)
                addressBar(draft)
                tabs(draft)
            } else {
                ContentUnavailableView(
                    "No Request Selected",
                    systemImage: "arrow.left",
                    description: Text("Pick a request in the sidebar, or create one.")
                )
            }
        }
        .padding(12)
        // Every field autosaves: edits go through this one draft, so a single
        // observation covers the URL, the tables, the body, auth, and scripts
        // alike. Command-S still writes immediately.
        .onChange(of: editor.draft) { editor.scheduleAutosave() }
        .overlay(alignment: .top) { curlNotice }
    }

    /// Return or moving focus away commits the name straight away, rather than
    /// waiting out the autosave delay.
    private func nameField(_ draft: Binding<APIRequest>) -> some View {
        TextField(editor.namePlaceholder, text: draft.name)
            .textFieldStyle(.plain)
            .font(.title3.weight(.medium))
            .focused($isNameFocused)
            .onSubmit { Task { await editor.flushAutosave() } }
            .onChange(of: isNameFocused) { _, isFocused in
                guard !isFocused else { return }
                Task { await editor.flushAutosave() }
            }
    }

    private func addressBar(_ draft: Binding<APIRequest>) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: draft.method) {
                ForEach(HTTPMethod.allCases) { method in
                    Text(method.rawValue)
                        .foregroundStyle(method.color)
                        .tag(method)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(draft.wrappedValue.bodyMode == .graphQL)
            .help(
                draft.wrappedValue.bodyMode == .graphQL
                    ? "GraphQL requests are always sent as POST."
                    : "HTTP method"
            )

            TextField("https://example.com/path?query=value", text: draft.url)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .variableTint(draft.wrappedValue.url, knownNames: editor.knownVariableNames)
                .onSubmit { Task { await editor.send() } }
                .onChange(of: draft.wrappedValue.url) { _, newValue in
                    importCurlIfNeeded(newValue)
                }

            Button {
                Task { await editor.send() }
            } label: {
                Label("Send", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(editor.isSending)
        }
    }

    private func tabs(_ draft: Binding<APIRequest>) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(label(for: tab, draft: draft.wrappedValue)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch selectedTab {
                case .params:
                    KeyValueTableView(
                        items: draft.params, knownVariableNames: editor.knownVariableNames
                    )
                case .headers:
                    KeyValueTableView(
                        items: draft.headers, knownVariableNames: editor.knownVariableNames
                    )
                case .body:
                    BodyTabView(draft: draft, knownVariableNames: editor.knownVariableNames)
                case .auth:
                    AuthTabView(auth: draft.auth, knownVariableNames: editor.knownVariableNames)
                case .scripts:
                    ScriptsTabView(draft: draft)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 8)
        }
    }

    /// Counts on the tab label, so a request's shape is visible without
    /// clicking through every tab.
    private func label(for tab: Tab, draft: APIRequest) -> String {
        switch tab {
        case .params:
            let count = draft.params.filter { !$0.isBlank }.count
            return count > 0 ? "Params (\(count))" : "Params"
        case .headers:
            let count = draft.headers.filter { !$0.isBlank }.count
            return count > 0 ? "Headers (\(count))" : "Headers"
        case .body:
            return draft.bodyMode == .none ? "Body" : "Body •"
        case .auth:
            return draft.auth.type == .none ? "Auth" : "Auth •"
        case .scripts:
            return draft.postResponseScript.isEmpty ? "Scripts" : "Scripts •"
        }
    }

    /// A URL never legitimately begins with `curl `, so treating that as an
    /// import is unambiguous -- and it works however the text arrived
    /// (paste, drop, or typing).
    private func importCurlIfNeeded(_ text: String) {
        guard CurlParser.looksLikeCurlCommand(text) else { return }
        editor.apply(CurlParser.parse(text))
    }

    @ViewBuilder
    private var curlNotice: some View {
        if let notice = editor.curlImportNotice {
            Text(notice)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.thickMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(6))
                    editor.curlImportNotice = nil
                }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
