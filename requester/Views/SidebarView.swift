import SwiftUI
import UniformTypeIdentifiers

/// Project / request outline with create, rename, and delete. Requests carry a
/// coloured method badge and fall back to a name derived from their URL until
/// they have been named explicitly; a dot marks one with unsaved edits.
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
    @State private var newProjectName = ""
    @State private var isCreatingProject = false

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.projectList) { project in
                projectRow(project)
                    .tag(SidebarSelection.project(project.id))
                    .contextMenu { projectMenu(project.id) }

                if model.isExpanded(project.id) {
                    ForEach(model.requestsByProject[project.id] ?? []) { request in
                        requestRow(request, in: project.id)
                            .tag(
                                SidebarSelection.request(
                                    projectID: project.id, requestID: request.id
                                )
                            )
                            .contextMenu { requestMenu(projectID: project.id, requestID: request.id) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { toolbar }
        .overlay {
            if model.projectList.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder.badge.plus")
                } description: {
                    Text("Create a project to hold your requests.")
                } actions: {
                    Button("New Project") { isCreatingProject = true }
                }
            }
        }
        .fileImporter(
            isPresented: $model.isChoosingImportFile,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await model.importPostmanCollection(from: url) }
        }
        .sheet(item: $model.importSummary) { summary in
            ImportSummaryView(summary: summary)
        }
        .alert("New Project", isPresented: $isCreatingProject) {
            TextField("Project name", text: $newProjectName)
            Button("Create") {
                let name = newProjectName.trimmingCharacters(in: .whitespaces)
                newProjectName = ""
                guard !name.isEmpty else { return }
                Task { await model.createProject(name: name) }
            }
            Button("Cancel", role: .cancel) { newProjectName = "" }
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

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                isCreatingProject = true
            } label: {
                Label("Project", systemImage: "folder.badge.plus")
            }
            .help("Create a new project")

            Button {
                guard let projectID = model.targetProjectIDForNewRequest else { return }
                Task { await model.createRequest(projectID: projectID) }
            } label: {
                Label("Request", systemImage: "plus")
            }
            .help("Create a new request in the selected project")
            .disabled(model.targetProjectIDForNewRequest == nil)

            Spacer()

            Button {
                model.isChoosingImportFile = true
            } label: {
                if model.isImporting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .labelStyle(.iconOnly)
                }
            }
            .help("Import collection")
            .disabled(model.isImporting)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
        .background(.bar)
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

        return HStack(spacing: 6) {
            Text(request.method.rawValue)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(request.method.color)
                .frame(width: 52, alignment: .leading)

            Text(model.displayName(for: request))
                .lineLimit(1)
                .truncationMode(.middle)
                .italic(isDirty)

            if isDirty {
                Circle()
                    .fill(.tint)
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
        }
        .padding(.vertical, 2)
        .padding(.leading, 20)
    }

    // MARK: - Menus

    @ViewBuilder
    private func projectMenu(_ projectID: String) -> some View {
        Button("New Request") {
            Task { await model.createRequest(projectID: projectID) }
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
