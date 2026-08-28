import SwiftUI
import UniformTypeIdentifiers

/// The window the app opens on: pick a project to work in, or make one.
///
/// A project opens in its own window, so this closes itself once it has opened
/// one -- it is a way in, not a pane to keep around. It comes back from
/// File ▸ Open Project… (⌘O).
struct LauncherView: View {
    @Bindable var launch: LaunchState

    @State private var projects: [Project] = []
    @State private var showsAllProjects = false

    /// The row the pointer is over, so the trash appears where it is useful
    /// rather than sitting on every row as a standing invitation.
    @State private var hoveredProjectID: String?
    @State private var deleteTarget: Project?

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if case .failed(let message) = launch.phase {
                folderProblem(message)
            } else {
                content
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .task { await reload() }
        .fileImporter(
            isPresented: $launch.isChoosingImportFile,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                if let id = await launch.importCollection(from: url) { open(id) }
                await reload()
            }
        }
        .sheet(item: $launch.importSummary) { summary in
            ImportSummaryView(summary: summary)
        }
        .confirmationDialog(
            deleteTarget.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: .init(
                get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { project in
            Button("Delete", role: .destructive) {
                deleteTarget = nil
                Task {
                    await launch.deleteProject(project.id)
                    await reload()
                }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { _ in
            Text("Its requests, history, and variables will be deleted. This cannot be undone.")
        }
        .alert(
            "Something went wrong",
            isPresented: .init(
                get: { launch.errorMessage != nil },
                set: { if !$0 { launch.errorMessage = nil } }
            ),
            presenting: launch.errorMessage
        ) { _ in
            Button("OK") { launch.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Requester")
                .font(.system(size: 26, weight: .semibold))
            Text("Open a project, or start a new one.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if projects.isEmpty {
                    Text("No projects yet.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                } else {
                    section("RECENT", projects: recents)

                    // Only worth offering once there is something it would
                    // actually reveal.
                    if !others.isEmpty {
                        DisclosureGroup(isExpanded: $showsAllProjects) {
                            VStack(spacing: 0) {
                                ForEach(others) { row(for: $0) }
                            }
                        } label: {
                            Text("All Projects (\(others.count) more)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }

        Divider()
        actions
    }

    /// The recents that still exist. A project opened once and then deleted
    /// from the folder simply stops being offered.
    private var recents: [Project] {
        let resolved = launch.recents.resolve(against: projects)
        // Nothing opened yet on this machine -- a shared or restored folder --
        // so the whole list is the best "recent" there is.
        return resolved.isEmpty ? projects : resolved
    }

    private var others: [Project] {
        let shown = Set(recents.map(\.id))
        return projects.filter { !shown.contains($0.id) }
    }

    private func section(_ title: String, projects: [Project]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(projects) { row(for: $0) }
            }
        }
    }

    private func row(for project: Project) -> some View {
        let isOpen = launch.openProjectIDs.contains(project.id)

        return HStack(spacing: 8) {
            Button {
                open(project.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(.tint)
                    Text(project.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                deleteTarget = project
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            // Deleting a project whose window is up would leave that window
            // showing something that is gone, and a save from it would write
            // the files back.
            .disabled(isOpen)
            .help(isOpen ? "Close its window before deleting it" : "Delete this project")
            .opacity(hoveredProjectID == project.id ? 1 : 0)
            .accessibilityLabel("Delete \(project.name)")

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
        .padding(.vertical, 1)
        .onHover { hoveredProjectID = $0 ? project.id : nil }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    guard let id = await launch.createProject() else { return }
                    open(id)
                }
            } label: {
                Label("New Project", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(launch.storage == nil)

            Button {
                launch.isChoosingImportFile = true
            } label: {
                if launch.isImporting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Import Collection…", systemImage: "square.and.arrow.down")
                }
            }
            .disabled(launch.storage == nil || launch.isImporting)

            Spacer()
        }
        .padding(16)
        .background(.bar)
    }

    private func folderProblem(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Could Not Open Your Data", systemImage: "folder.badge.questionmark")
        } description: {
            Text(message)
        } actions: {
            Button("Use the Default Folder") { launch.useDefaultFolder() }
                .buttonStyle(.borderedProminent)
            Button("Choose a Folder…") { launch.isChoosingFolder = true }
        }
    }

    /// Opening the same project twice focuses the window it is already in --
    /// that is what keying the window group by project id buys.
    private func open(_ projectID: String) {
        openWindow(id: WindowID.project, value: projectID)
        dismiss()
    }

    private func reload() async {
        projects = await launch.allProjects()
    }
}
