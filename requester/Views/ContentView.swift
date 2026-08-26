import SwiftUI

/// The main window: sidebar, then either the project detail or the editor over
/// the response panel, with history in a collapsible inspector on the right.
struct ContentView: View {
    /// Enough for the widest table the detail pane shows.
    static let detailMinimumWidth: CGFloat = 520

    @Bindable var model: AppModel
    @State private var isHistoryVisible = true

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            detail
                // Claims its own share of the window, so the sidebar and the
                // inspector keep theirs. The three minimums plus the window's
                // own minimum width are one budget: 200 + 520 + 260 < 1180.
                .frame(minWidth: Self.detailMinimumWidth)
                .inspector(isPresented: $isHistoryVisible) {
                    HistoryPanelView(model: model, history: model.historyPanel)
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
                }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.editor.save() }
                } label: {
                    Label("Save", systemImage: "tray.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.editor.isDirty)
                .help(model.editor.isDirty ? "Save this request" : "No unsaved changes")
            }
            ToolbarItem {
                Button {
                    isHistoryVisible.toggle()
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .help("Show or hide history")
            }
        }
        .task { await model.load() }
        .alert(
            "Something went wrong",
            isPresented: .init(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button("OK") { model.errorMessage = nil }
        } message: { message in
            Text(message)
        }
        .alert(
            "Request failed",
            isPresented: .init(
                get: { model.editor.errorMessage != nil },
                set: { if !$0 { model.editor.errorMessage = nil } }
            ),
            presenting: model.editor.errorMessage
        ) { _ in
            Button("OK") { model.editor.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .project(let projectID):
            ProjectDetailView(model: model, projectID: projectID)

        case .request:
            VerticalSplit(minTopHeight: 240, minBottomHeight: 200) {
                RequestEditorView(model: model, editor: model.editor)
            } bottom: {
                ResponsePanelView(
                    entry: model.editor.lastEntry, isSending: model.editor.isSending
                )
            }

        case nil:
            ContentUnavailableView(
                "Nothing Selected",
                systemImage: "square.on.square.dashed",
                description: Text("Pick a project or request in the sidebar to begin.")
            )
        }
    }
}
