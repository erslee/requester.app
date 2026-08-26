import SwiftUI

/// The main window: sidebar, then either the project detail or the editor over
/// the response panel, with history in a collapsible pane on the right.
struct ContentView: View {
    /// One width budget for the whole window. None of the three panes can be
    /// compressed below these, so the window is not allowed to be narrower than
    /// their sum -- otherwise the layout would have to overflow to satisfy them.
    static let sidebarMinimumWidth: CGFloat = 190
    static let detailMinimumWidth: CGFloat = 460
    static let inspectorMinimumWidth: CGFloat = 250

    static var minimumWindowWidth: CGFloat {
        sidebarMinimumWidth + detailMinimumWidth + inspectorMinimumWidth
    }

    @Bindable var model: AppModel
    @State private var isHistoryVisible = true

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(
                    min: Self.sidebarMinimumWidth, ideal: 240, max: 340
                )
        } detail: {
            // History sits in a split this view measures, rather than in an
            // `.inspector`. The inspector autosaved an absolute width, so one
            // captured in a narrow window came back unchanged in a wide one and
            // left the panel a sliver of its minimum.
            if isHistoryVisible {
                ResizableSplit(
                    axis: .horizontal,
                    minimumFirst: Self.detailMinimumWidth,
                    minimumSecond: Self.inspectorMinimumWidth,
                    initialFraction: 0.72
                ) {
                    detail
                } second: {
                    HistoryPanelView(model: model, history: model.historyPanel)
                }
            } else {
                detail
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
            ResizableSplit(
                axis: .vertical, minimumFirst: 240, minimumSecond: 200
            ) {
                RequestEditorView(model: model, editor: model.editor)
            } second: {
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
