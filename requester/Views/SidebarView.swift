import SwiftUI
import UniformTypeIdentifiers

/// The window's project and its requests, with create, rename, and delete.
/// Requests carry a coloured method badge and fall back to a name derived from
/// their URL until they have been named explicitly; a dot marks one with
/// unsaved edits.
///
/// A window shows one project, so the project row here is a single root -- it
/// is what opens the project's own pane (variables, global headers, the API
/// document). Making a project is not a sidebar action any more: a new project
/// gets a new window, so it lives in the File menu.
///
/// The bar along the bottom holds the new-request button and the filter, the
/// way Xcode's navigator does -- the filter is always available, and always in
/// the same place, rather than being something to open first.
///
/// The outline is built from flat, individually-taggable rows with disclosure
/// state this view owns, rather than `List(children:)`: that variant offers no
/// control over expansion, so a request created inside a collapsed project
/// could not be selected and the selection binding would snap back.
struct SidebarView: View {
    @Bindable var model: AppModel

    @State private var renameTarget: RenameTarget?
    @State private var renameText = ""
    @State private var deleteTarget: SidebarSelection?
    @FocusState private var isFilterFocused: Bool

    var body: some View {
        list
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.projectList) { project in
                rows(for: project)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .onChange(of: model.filterFocusRequests) { isFilterFocused = true }
        .sheet(item: $model.specSummary) { summary in
            SpecSyncSummaryView(summary: summary.result)
        }
        .alert(
            "Rename",
            isPresented: .init(
                get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } }
            ),
            presenting: renameTarget
        ) { target in
            TextField("Name", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                renameText = ""
                guard !trimmed.isEmpty else { return }
                Task { await rename(target, to: trimmed) }
            }
            Button("Cancel", role: .cancel) { renameText = "" }
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: .init(
                get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let target = deleteTarget else { return }
                deleteTarget = nil
                Task { await delete(target) }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        }
    }

    // MARK: - Bottom bar

    /// New request on the left, filter field filling the rest -- the shape of
    /// Xcode's navigator bar.
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 8) {
                Button {
                    guard let projectID = model.targetProjectIDForNewRequest else { return }
                    Task { await model.createRequest(projectID: projectID) }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Create a new request in this project")
                .disabled(model.targetProjectIDForNewRequest == nil)
                .accessibilityLabel("Request")

                filterField
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private var filterField: some View {
        HStack(spacing: 5) {
            Image(
                systemName: model.isFiltering
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
            .foregroundStyle(model.isFiltering ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

            TextField("Filter", text: $model.filterQuery)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isFilterFocused)
                // Return has nothing left to do -- the list is already the
                // result -- so it just gets out of the field.
                .onSubmit { isFilterFocused = false }

            if model.isFiltering {
                Button {
                    model.clearFilter()
                    isFilterFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Clear the filter")
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(.background.secondary)
        )
        .overlay(
            Capsule().strokeBorder(.separator, lineWidth: 1)
        )
    }

    /// Split out of `body`: inlined, the row builders plus their tags, ids, and
    /// context menus are one expression the type-checker gives up on.
    @ViewBuilder
    private func rows(for project: Project) -> some View {
        let projectTag = SidebarSelection.project(project.id)
        projectRow(project)
            .tag(projectTag)
            .id(projectTag)
            .contextMenu { projectMenu(project.id) }

        if model.isExpanded(project.id) {
            ForEach(model.visibleRequests(in: project.id)) { request in
                let requestTag = SidebarSelection.request(
                    projectID: project.id, requestID: request.id
                )
                requestRow(request, in: project.id)
                    .tag(requestTag)
                    .id(requestTag)
                    .contextMenu { requestMenu(projectID: project.id, requestID: request.id) }
            }
        }
    }

    // MARK: - Rows

    private func projectRow(_ project: Project) -> some View {
        HStack(spacing: 4) {
            Button {
                model.toggleExpansion(project.id)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(model.isExpanded(project.id) ? 90 : 0))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                model.isExpanded(project.id)
                    ? "Collapse \(project.name)" : "Expand \(project.name)"
            )

            Image(systemName: "folder")
                .foregroundStyle(.secondary)

            Text(project.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    private func requestRow(_ request: APIRequest, in projectID: String) -> some View {
        let isDirty = model.editor.isDirty && model.editor.draft?.id == request.id
        let isRemoved = request.spec?.isRemoved == true

        return HStack(spacing: 6) {
            Text(request.method.rawValue)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(request.method.color)
                .frame(width: 52, alignment: .leading)

            Text(model.displayName(for: request))
                .lineLimit(1)
                .truncationMode(.middle)
                .italic(isDirty)
                .strikethrough(isRemoved)

            if isDirty {
                Circle()
                    .fill(.tint)
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
        }
        // Dimmed rather than disabled: the endpoint is gone from the document,
        // but the request is still entirely usable -- open it, edit it, send it,
        // read its history.
        .opacity(isRemoved ? 0.55 : 1)
        .help(isRemoved ? removedHelp(request) : "")
        .padding(.vertical, 2)
        .padding(.leading, 20)
    }

    private func removedHelp(_ request: APIRequest) -> String {
        guard let removedAt = request.spec?.removedAt else { return "" }
        return "No longer in the API document as of "
            + removedAt.formatted(date: .abbreviated, time: .shortened)
            + ". Kept, and still usable."
    }

    // MARK: - Menus

    @ViewBuilder
    private func projectMenu(_ projectID: String) -> some View {
        Button("New Request") {
            Task { await model.createRequest(projectID: projectID) }
        }
        let removed = model.removedRequestCount(in: projectID)
        if removed > 0 || model.showsRemovedEndpoints {
            Divider()
            Toggle("Show Removed Endpoints (\(removed))", isOn: $model.showsRemovedEndpoints)
        }
        Divider()
        Button("Rename Project…") { renameTarget = .project(projectID) }
        Button("Delete Project…", role: .destructive) {
            deleteTarget = .project(projectID)
        }
    }

    @ViewBuilder
    private func requestMenu(projectID: String, requestID: String) -> some View {
        Button("Rename Request…") {
            renameTarget = .request(projectID: projectID, requestID: requestID)
        }
        Button("Delete Request…", role: .destructive) {
            deleteTarget = .request(projectID: projectID, requestID: requestID)
        }
    }

    private var deleteConfirmationTitle: String {
        switch deleteTarget {
        case .project: "Delete this project and all its requests and history?"
        case .request: "Delete this request?"
        case nil: ""
        }
    }

    private func rename(_ target: RenameTarget, to newName: String) async {
        switch target {
        case .project(let projectID):
            await model.renameProject(projectID, to: newName)
        case .request(let projectID, let requestID):
            await model.renameRequest(projectID: projectID, requestID: requestID, to: newName)
        }
    }

    private func delete(_ target: SidebarSelection) async {
        switch target {
        case .project(let projectID):
            await model.deleteProject(projectID)
        case .request(let projectID, let requestID):
            await model.deleteRequest(projectID: projectID, requestID: requestID)
        }
    }
}

/// What the rename alert is editing.
enum RenameTarget: Identifiable {
    case project(String)
    case request(projectID: String, requestID: String)

    var id: String {
        switch self {
        case .project(let id): "project-\(id)"
        case .request(_, let requestID): "request-\(requestID)"
        }
    }
}
