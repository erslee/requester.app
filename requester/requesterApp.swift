import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct RequesterApp: App {
    @State private var launch = LaunchState()

    /// The frontmost window's model, so a menu command acts on the window the
    /// user is actually looking at. With one project per window there is no
    /// single "the" model any more, and reaching for one would drive the wrong
    /// window as soon as a second is open.
    @FocusedValue(\.appModel) private var focusedModel

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Declared first, so it is the window the app comes up in.
        Window("Requester", id: WindowID.launcher) {
            LauncherView(launch: launch)
        }
        .defaultSize(width: 560, height: 480)
        .commands { commands }

        WindowGroup(id: WindowID.project, for: String.self) { $projectID in
            ProjectWindow(launch: launch, projectID: projectID)
                // SwiftUI turns this into the window's own minimum, so dragging
                // an edge stops here. What it does *not* do is correct a frame
                // restored from a previous launch that is already smaller --
                // and a window narrower than its content is exactly what left
                // the sidebar and inspector hanging outside the edges.
                // WindowMinimumSize fixes that case up.
                .frame(minWidth: ContentView.minimumWindowWidth, minHeight: 560)
                .background(
                    WindowMinimumSize(width: ContentView.minimumWindowWidth, height: 560)
                )
        }
        .defaultSize(width: 1320, height: 860)
        // The app always starts on the launcher. Without this, macOS restores
        // the project windows from the last session -- but not the project id
        // each was showing, so they come back as empty "No Project Open"
        // windows *and* suppress the launcher, leaving no way in at all.
        .restorationBehavior(.disabled)
    }

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") { newProject() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(launch.storage == nil)

            Button("Open Project…") { openWindow(id: WindowID.launcher) }
                .keyboardShortcut("o", modifiers: .command)

            Divider()
            // The importer's picker and summary live on the launcher, because
            // an import produces a *new* project -- so the launcher is brought
            // forward rather than the command acting invisibly in a window that
            // will not be showing the result.
            Button("Import Collection…") {
                openWindow(id: WindowID.launcher)
                launch.isChoosingImportFile = true
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(launch.storage == nil || launch.isImporting)

            Divider()
            Button("Reveal Data Folder in Finder") { launch.revealDataFolder() }
        }

        CommandGroup(after: .textEditing) {
            // The filter bar is always on screen, so this only moves the
            // cursor into it -- there is nothing to open.
            Button("Filter Requests…") { focusedModel?.focusFilter() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(focusedModel == nil)

            // Acts on the selected request, so the title says which way it
            // will go rather than making the user read the sidebar first.
            Button(favoriteCommandTitle) {
                guard let model = focusedModel, let requestID = model.selectedRequestID
                else { return }
                Task { await model.toggleFavorite(
                    projectID: model.projectID, requestID: requestID
                ) }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(focusedModel?.selectedRequestID == nil)

            Divider()
            // Acts on the request in the editor rather than the sidebar
            // selection: the export carries unsaved edits, which only the
            // draft has.
            Button("Copy as curl") { focusedModel?.copyDraftAsCurl() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(focusedModel?.editor.draft == nil)
        }
    }

    private var favoriteCommandTitle: String {
        guard let model = focusedModel, let requestID = model.selectedRequestID,
              model.isFavorite(requestID: requestID)
        else { return "Add to Favorites" }
        return "Remove from Favorites"
    }

    private func newProject() {
        guard let id = launch.createProject() else { return }
        openWindow(id: WindowID.project, value: id)
    }
}

enum WindowID {
    static let launcher = "launcher"
    static let project = "project"
}

/// Lets a menu command reach the frontmost window's model. `ContentView`
/// publishes it; the `App` reads it.
struct AppModelFocusedValueKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusedValueKey.self] }
        set { self[AppModelFocusedValueKey.self] = newValue }
    }
}

/// One project's window. The model is built once the window knows which
/// project it is for, and rebuilt if that ever changes.
private struct ProjectWindow: View {
    let launch: LaunchState
    let projectID: String?

    @State private var model: AppModel?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let model {
                ContentView(model: model)
            } else if case .failed(let message) = launch.phase {
                DataFolderProblemView(message: message)
            } else {
                // A window restored by macOS with no project value, or one whose
                // project has since gone from the data folder.
                ContentUnavailableView {
                    Label("No Project Open", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("This window is not showing a project.")
                } actions: {
                    Button("Open a Project…") { openWindow(id: WindowID.launcher) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .task(id: projectID) { model = await launch.model(for: projectID) }
        // Registered while the window is up, so the launcher can refuse to
        // delete a project out from under a window that is showing it.
        .onAppear { if let projectID { launch.windowOpened(projectID) } }
        .onDisappear {
            guard let projectID else { return }
            // A window that never wrote its project takes it with it.
            launch.windowClosed(projectID, wasSaved: model?.isProjectUnsaved == false)
        }
    }
}

/// Shown when the data folder itself could not be opened -- there is nothing to
/// show a project from until that is resolved.
private struct DataFolderProblemView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Could Not Open Your Data", systemImage: "folder.badge.questionmark")
        } description: {
            Text(message)
        }
    }
}

/// Opens the app's data folder, creates projects, and imports collections --
/// everything that is about the folder as a whole rather than about one
/// project. Shared by every window.
///
/// There is no first-run prompt and nothing to configure: the folder lives in
/// the app's own container, needs no permission, and the app comes up straight
/// into the launcher.
@MainActor
@Observable
final class LaunchState {
    enum Phase {
        case ready(LocalFileStorage)
        case failed(String)
    }

    /// Overrides the data folder, for scripted runs and UI tests. An absolute
    /// path must be one the sandbox already allows; a bare name is resolved
    /// inside the app's own container, which is how UI tests get a throwaway
    /// folder (their runner is sandboxed too and cannot create one there).
    static let dataRootEnvironmentKey = "REQUESTER_DATA_ROOT"

    let recents = RecentProjectsStore()

    private(set) var phase: Phase = .failed("")
    private(set) var currentRoot: URL?

    /// Whether the collection picker is open, kept separate from whether an
    /// import is running -- sharing one flag would have the picker reopen
    /// itself the moment the import finished.
    var isChoosingImportFile = false
    var isImporting = false

    /// Shown after an import, so what did and did not come across is visible.
    var importSummary: AppModel.ImportSummary?

    /// Surfaced as an alert on the launcher.
    var errorMessage: String?

    /// Projects that currently have a window. Deleting one of these is refused
    /// rather than leaving a window showing data that is no longer there.
    private(set) var openProjectIDs: Set<String> = []

    /// Projects made but not yet written, by id.
    ///
    /// A new project is nothing but a name until the user changes something,
    /// so it is held here and handed to its window rather than written -- open
    /// one, close it, and there is no empty project left in the folder. The
    /// window writes it on the first change; see `AppModel`.
    private var unsavedProjects: [String: Project] = [:]

    var storage: LocalFileStorage? {
        guard case .ready(let storage) = phase else { return nil }
        return storage
    }

    init() {
        open(startupRoot())
    }

    // MARK: - The data folder

    /// The default folder lives inside the sandbox container, where it is not
    /// obvious in Finder -- so there is a command to go straight to it.
    func revealDataFolder() {
        guard let currentRoot else { return }
        NSWorkspace.shared.activateFileViewerSelecting([currentRoot])
    }

    private func startupRoot() -> URL {
        if let path = ProcessInfo.processInfo.environment[Self.dataRootEnvironmentKey],
           !path.isEmpty {
            return path.hasPrefix("/")
                ? URL(filePath: path, directoryHint: .isDirectory)
                : FileManager.default.temporaryDirectory.appending(path: path)
        }
        return StorageRootStore.defaultRoot
    }

    private func open(_ url: URL) {
        do {
            let storage = try LocalFileStorage(root: url)
            currentRoot = url
            phase = .ready(storage)
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    // MARK: - Projects

    /// Every project in the folder, newest-named order, for the launcher.
    func allProjects() async -> [Project] {
        guard let storage else { return [] }
        return (try? await ProjectRepository(storage: storage).listAll()) ?? []
    }

    /// The model for one window. `nil` when there is no folder, no project id,
    /// or the id no longer resolves to anything on disk.
    func model(for projectID: String?) async -> AppModel? {
        guard let storage, let projectID else { return nil }

        // One that has never been written yet: hand its in-memory copy to the
        // window, which persists it as soon as anything changes.
        if let unsaved = unsavedProjects[projectID] {
            return AppModel(storage: storage, projectID: projectID, unsavedProject: unsaved)
        }

        guard let project = try? await ProjectRepository(storage: storage).get(projectID),
              project != nil
        else { return nil }

        recents.markOpened(projectID)
        return AppModel(storage: storage, projectID: projectID)
    }

    func windowOpened(_ projectID: String) {
        openProjectIDs.insert(projectID)
    }

    /// Deletes a project and everything remembered about it: its requests,
    /// history and variables on disk, its place in the recents list, and the
    /// sidebar state stored against it.
    ///
    /// Refused while its window is open -- the window would carry on showing a
    /// project that no longer exists, and saving from it would write the files
    /// back.
    func deleteProject(_ projectID: String) async {
        guard let storage, !openProjectIDs.contains(projectID) else { return }
        do {
            try await ProjectRepository(storage: storage).delete(projectID)
            recents.forget(projectID)
            InterfaceStateStore(projectID: projectID).forgetProject()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// Makes a project and hands back its id, for the caller to open a window
    /// on. Named rather than prompted: the project pane's name field is the
    /// first thing in the new window, and typing there beats a modal.
    ///
    /// Nothing is written here. The project exists only in memory until its
    /// window changes something, so making one and closing it again leaves no
    /// empty project behind.
    func createProject(named name: String = "Untitled Project") -> String? {
        guard storage != nil else { return nil }
        let project = Project(id: ProjectRepository.newIdentifier(), name: name)
        unsavedProjects[project.id] = project
        return project.id
    }

    /// Forgets an unsaved project once its window has gone, so an abandoned one
    /// does not sit in memory for the rest of the session.
    func windowClosed(_ projectID: String, wasSaved: Bool) {
        openProjectIDs.remove(projectID)
        if !wasSaved { unsavedProjects[projectID] = nil }
    }

    /// Imports a Postman collection as a new project, returning its id.
    ///
    /// The whole collection lands in one project: Postman folders have no
    /// equivalent here, so their names are folded into the request names.
    func importCollection(from url: URL) async -> String? {
        guard let storage else { return nil }
        isImporting = true
        defer { isImporting = false }

        // A file chosen through the importer is security-scoped, and reading it
        // without taking that scope fails under the sandbox.
        let hasScope = url.startAccessingSecurityScopedResource()
        defer { if hasScope { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            let collection = try PostmanImporter.collection(from: data)

            let projects = ProjectRepository(storage: storage)
            let requests = RequestRepository(storage: storage)
            let variables = VariableRepository(storage: storage)

            let project = try await projects.create(name: collection.name)
            try await variables.setMany(
                projectID: project.id, writes: collection.variables, source: .manual
            )
            // Folders the collection declared but left empty. The ones with
            // requests in them are implied by those requests.
            if !collection.folders.isEmpty {
                _ = try await projects.setFolders(collection.folders, for: project.id)
            }

            for imported in collection.requests {
                var request = try await requests.create(projectID: project.id)
                let id = request.id
                request = imported
                request.id = id
                request.projectID = project.id
                _ = try await requests.save(request)
            }

            // An import is written straight away: it arrives with requests in
            // it, so there is no empty project to avoid.
            importSummary = AppModel.ImportSummary(
                collectionName: collection.name,
                requestCount: collection.requests.count,
                variableCount: collection.variables.count,
                warnings: collection.warnings,
                scriptsNeedingReview: collection.scriptsNeedingReview
            )
            return project.id
        } catch {
            errorMessage = Self.describe(error)
            return nil
        }
    }

    /// Includes the recovery suggestion, so the message says what to do next
    /// rather than only what went wrong.
    private static func describe(_ error: any Error) -> String {
        guard let localized = error as? any LocalizedError else {
            return error.localizedDescription
        }
        return [localized.errorDescription, localized.recoverySuggestion]
            .compactMap(\.self)
            .joined(separator: " ")
    }
}
