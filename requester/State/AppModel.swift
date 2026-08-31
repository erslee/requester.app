import Foundation

/// Root observable state for one window: the wired dependency graph, the
/// request tree behind the sidebar, the project's variables, and the current
/// selection.
///
/// A window shows exactly one project, so this is scoped to `projectID`.
/// Repositories still address every project -- the storage layer is shared
/// across windows -- but nothing above this line reads outside the one project
/// the window is for.
///
/// Replaces the Qt controllers and their signals -- observation handles the
/// change notification that `projects_changed` / `requests_changed` /
/// `variables_changed` used to carry by hand.
@MainActor
@Observable
final class AppModel {
    /// The project this window is for. Fixed for the model's whole life --
    /// opening a different project means a different window.
    let projectID: String

    let projects: ProjectRepository
    let requests: RequestRepository
    let variables: VariableRepository
    let history: HistoryRepository

    let editor: EditorModel
    let historyPanel: HistoryModel
    let specSync: SpecSyncService

    /// The projects this window shows: exactly one, or none while it is
    /// loading or after the project has been deleted. Kept as a list because
    /// the sidebar renders it as the tree's single root row.
    var projectList: [Project] = []

    /// The window's project, when it has loaded.
    var project: Project? { projectList.first }

    var requestsByProject: [String: [APIRequest]] = [:]
    var variablesByProject: [String: [String: Variable]] = [:]

    /// Set when the project this window is for has been deleted, so the window
    /// can close itself rather than sit on an empty tree.
    private(set) var wasDeleted = false

    /// A project that has been made but not yet written.
    ///
    /// A new project is held here rather than on disk until the user changes
    /// something, so opening one and closing it again leaves nothing behind --
    /// no "Untitled Project 4" for a window that was never used. The first
    /// write of any kind materialises it; see `write(_:)`.
    private var unsavedProject: Project?

    /// Whether this window's project exists on disk yet.
    var isProjectUnsaved: Bool { unsavedProject != nil }

    /// The row the sidebar should scroll into view.
    ///
    /// Set only when something other than a click moves the selection -- so
    /// far, creating a request. A click is already on screen, and scrolling to
    /// centre it would pull the list out from under the pointer. The sidebar
    /// clears this once it has scrolled.
    var pendingScrollTarget: SidebarSelection?

    /// Folders the user has collapsed, by full path.
    private var collapsedFolders: Set<String> = [] {
        didSet { interfaceState.collapsedFolders = collapsedFolders }
    }

    var selection: SidebarSelection? {
        didSet {
            interfaceState.selection = selection
            handleSelectionChange(from: oldValue)
        }
    }

    /// Surfaced as an alert. A failed read or write should say so rather than
    /// vanish into the console.
    var errorMessage: String?

    /// Whether the file picker for an API document is open, and whether a sync
    /// is running -- separate for the same reason as the import pair above.
    var isChoosingSpecFile = false
    var isSyncingSpec = false

    /// Shown after a sync, so what changed is visible rather than silent.
    var specSummary: SpecSyncSummary?

    struct SpecSyncSummary: Identifiable {
        let id = UUID()
        var result: SpecSyncService.Summary
    }

    /// What an import brought in. Produced by the launcher, which owns the
    /// import flow -- a collection becomes a new project, and a new project
    /// means a new window.
    struct ImportSummary: Identifiable {
        let id = UUID()
        var collectionName: String
        var requestCount: Int
        var variableCount: Int
        var warnings: [String]
        var scriptsNeedingReview: [String]
    }

    private let interfaceState: InterfaceStateStore

    init(
        storage: any StorageBackend,
        projectID: String,
        unsavedProject: Project? = nil,
        interfaceState: InterfaceStateStore? = nil
    ) {
        self.projectID = projectID
        self.unsavedProject = unsavedProject
        self.interfaceState = interfaceState ?? InterfaceStateStore(projectID: projectID)
        let projects = ProjectRepository(storage: storage)
        let requests = RequestRepository(storage: storage)
        let variables = VariableRepository(storage: storage)
        let history = HistoryRepository(storage: storage)

        self.projects = projects
        self.requests = requests
        self.variables = variables
        self.history = history

        self.editor = EditorModel(
            requests: requests,
            sender: HistoryService(
                executor: HTTPExecutor(),
                history: history,
                variables: variables,
                projects: projects,
                scripts: ScriptRunner()
            )
        )
        self.historyPanel = HistoryModel(query: HistoryQuery(storage: storage), history: history)
        self.specSync = SpecSyncService(
            requests: requests, projects: projects, variables: variables, fetcher: SpecFetcher()
        )

        editor.onSaved = { [weak self] request in
            await self?.reloadRequests(projectID: request.projectID)
        }
        editor.onSent = { [weak self] entry in
            guard let self else { return }
            await historyPanel.refresh()
            historyPanel.selectedEntryID = entry.id
            if entry.scriptResult?.variablesWritten.isEmpty == false {
                await reloadVariables(projectID: entry.projectID)
            }
        }
    }

    // MARK: - Loading

    func load() async {
        await reloadProjects()
        await reloadRequests(projectID: projectID)
        restoreInterfaceState()
    }

    /// Brings the window back as it was left.
    ///
    /// What was selected is checked against what actually exists first: the
    /// data folder may have been changed or edited by hand, and a selection
    /// pointing at something gone would leave the window on a blank pane with
    /// no way back. Falling back to the project's own pane is always valid.
    private func restoreInterfaceState() {
        isProjectCollapsed = interfaceState.isProjectCollapsed
        collapsedFolders = interfaceState.collapsedFolders

        guard let saved = interfaceState.selection,
              saved.projectID == projectID,
              let requestID = saved.requestID
        else {
            selection = .project(projectID)
            return
        }

        let stillExists = (requestsByProject[projectID] ?? [])
            .contains { $0.id == requestID }
        selection = stillExists ? saved : .project(projectID)
    }

    /// Re-reads just this window's project. A project that has gone leaves the
    /// list empty, which is what `wasDeleted` reports to the window.
    ///
    /// One that has never been written falls back to the unsaved copy, so the
    /// window shows its name and takes edits exactly as a saved one does.
    func reloadProjects() async {
        await run {
            if let stored = try await self.projects.get(self.projectID) {
                self.unsavedProject = nil
                self.projectList = [stored]
            } else {
                self.projectList = self.unsavedProject.map { [$0] } ?? []
            }
        }
    }

    func reloadRequests(projectID: String) async {
        await run {
            self.requestsByProject[projectID] =
                try await self.requests.listForProject(projectID)
        }
    }

    func reloadVariables(projectID: String) async {
        await run {
            let variables = try await self.variables.getAll(projectID: projectID)
            self.variablesByProject[projectID] = variables
            // Only the selected project's names drive the editor's tinting.
            if self.selection?.projectID == projectID {
                self.editor.knownVariableNames = Set(variables.keys)
            }
        }
    }

    // MARK: - Sidebar expansion

    /// Collapsed rather than expanded is tracked, so the project is expanded by
    /// default and a newly opened window does not appear empty.
    private var isProjectCollapsed = false {
        didSet { interfaceState.isProjectCollapsed = isProjectCollapsed }
    }

    /// Whether removed endpoints are listed. Remembered across launches, and
    /// forced on while one is selected -- hiding the row under the pane the
    /// user is looking at would strand them on a detail view with nothing in
    /// the sidebar pointing at it.
    var showsRemovedEndpoints: Bool {
        get { interfaceState.showsRemovedEndpoints || selectedRequestIsRemoved }
        set { interfaceState.showsRemovedEndpoints = newValue }
    }

    private var selectedRequestIsRemoved: Bool {
        guard case .request(let projectID, let requestID)? = selection else { return false }
        return (requestsByProject[projectID] ?? [])
            .first { $0.id == requestID }?.spec?.isRemoved == true
    }

    /// Everything the sidebar would list with no filter typed -- the removed
    /// endpoints rule applied, and nothing else.
    private var allVisibleRequests: [APIRequest] {
        let all = requestsByProject[projectID] ?? []
        guard !showsRemovedEndpoints else { return all }
        return all.filter { $0.spec?.isRemoved != true }
    }

    /// The rows the sidebar shows: what survives the removed-endpoint rule,
    /// then what survives the filter.
    ///
    /// The selected request is kept whatever the filter says. Filtering the row
    /// you are editing out from under yourself leaves the editor open on a
    /// request with nothing in the tree pointing at it, with no way back to it
    /// except clearing the field.
    func visibleRequests(in projectID: String) -> [APIRequest] {
        guard projectID == self.projectID else { return [] }
        let visible = allVisibleRequests
        guard isFiltering else { return visible }
        return visible.filter { matchesFilter($0) || $0.id == selection?.requestID }
    }

    /// Whether one request survives the filter.
    func matchesFilter(_ request: APIRequest) -> Bool {
        RequestFilter.matches(
            request, displayName: displayName(for: request), query: filterQuery
        )
    }

    /// How many the removed-endpoint toggle is hiding, so it can say what it
    /// would reveal. Independent of the filter, which is a separate narrowing.
    func removedRequestCount(in projectID: String) -> Int {
        (requestsByProject[projectID] ?? []).count { $0.spec?.isRemoved == true }
    }

    /// Takes a project id so the sidebar's row code reads the same as it did
    /// when a window held many; the window only ever asks about its own.
    func isExpanded(_ projectID: String) -> Bool {
        projectID == self.projectID && !isProjectCollapsed
    }

    func toggleExpansion(_ projectID: String) {
        guard projectID == self.projectID else { return }
        isProjectCollapsed.toggle()
    }

    /// The label a request shows in the sidebar.
    ///
    /// Follows the open draft rather than the saved copy, so typing a URL names
    /// the row straight away, and resolves `{{variables}}` first so a templated
    /// URL reads as the host it will actually reach.
    func displayName(for request: APIRequest) -> String {
        let current = editor.draft?.id == request.id ? (editor.draft ?? request) : request
        if !current.name.trimmingCharacters(in: .whitespaces).isEmpty {
            return current.name
        }
        let values = (variablesByProject[current.projectID] ?? [:]).mapValues(\.value)
        return RequestNaming.derivedName(
            fromURL: VariableResolver.resolve(current.url, with: values)
        )
    }

    func variables(forProject projectID: String) -> [Variable] {
        (variablesByProject[projectID] ?? [:]).values
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    // MARK: - History

    /// Opens a past send in the editor, switching the detail pane to it first.
    /// The entry is loaded *after* the selection settles, so the saved request
    /// the selection change loads does not overwrite it.
    func open(historyEntry entry: HistoryEntry) {
        guard let requestID = entry.requestID else { return }
        let target = SidebarSelection.request(projectID: entry.projectID, requestID: requestID)
        isProjectCollapsed = false

        historyPanel.selectedEntryID = entry.id

        Task {
            // Read the body back out of its blob first, so opening a large
            // response shows all of it rather than the trimmed stored copy.
            let full = await historyPanel.withFullBody(entry)
            if selection == target {
                editor.load(historyEntry: full)
            } else {
                pendingHistoryEntry = full
                selection = target
            }
        }
    }

    private var pendingHistoryEntry: HistoryEntry?

    // MARK: - Selection

    /// Loading anything new discards an unsaved draft, matching the original
    /// app -- the dirty marker never outlives the edit it describes.
    private func handleSelectionChange(from previous: SidebarSelection?) {
        guard selection != previous else { return }
        let selection = self.selection

        Task {
            // Commit whatever the autosave timer has not written yet, while the
            // outgoing draft is still the one in the editor.
            await editor.flushAutosave()

            guard let selection else {
                editor.clear()
                return
            }
            await reloadVariables(projectID: selection.projectID)

            switch selection {
            case .project(let projectID):
                editor.clear()
                await historyPanel.showProject(projectID)
            case .folder(let projectID, _):
                // A folder has no request to open, and its history is the
                // project's -- there is no per-folder history to scope to.
                editor.clear()
                await historyPanel.showProject(projectID)
            case .request(let projectID, let requestID):
                await run {
                    guard let request = try await self.requests.get(
                        projectID: projectID, requestID: requestID
                    ) else { return }
                    if let pending = self.pendingHistoryEntry, pending.requestID == requestID {
                        self.pendingHistoryEntry = nil
                        self.editor.load(historyEntry: pending)
                        self.historyPanel.selectedEntryID = pending.id
                    } else {
                        self.editor.load(request)
                        // No past response is shown until one is asked for, so
                        // no history row is marked active either.
                        self.historyPanel.selectedEntryID = nil
                    }
                }
                await historyPanel.showRequest(projectID: projectID, requestID: requestID)
            }
        }
    }

    // MARK: - Projects and requests

    func renameProject(_ projectID: String, to name: String) async {
        await write {
            _ = try await self.projects.rename(projectID, to: name)
            await self.reloadProjects()
        }
    }

    /// Deletes the window's project. The window closes itself once this lands
    /// -- there is nothing left for it to show.
    func deleteProject(_ projectID: String) async {
        guard projectID == self.projectID else { return }
        // Deliberately `run`, not `write`: a project that was never written has
        // nothing to delete, and materialising it first just to remove it again
        // is the opposite of what deferring the write is for.
        await run {
            if self.unsavedProject == nil {
                try await self.projects.delete(projectID)
            }
            self.unsavedProject = nil
            self.interfaceState.forgetProject()
            self.projectList = []
            self.requestsByProject[projectID] = nil
            self.variablesByProject[projectID] = nil
            self.selection = nil
            self.wasDeleted = true
        }
    }

    func createRequest(projectID: String, folder: [String] = []) async {
        await write {
            let request = try await self.requests.create(projectID: projectID, folder: folder)
            // Expand first: a row inside a collapsed project or folder cannot
            // be selected, and the List would snap the selection back.
            self.isProjectCollapsed = false
            self.expand(folder: folder)
            await self.reloadRequests(projectID: projectID)

            let target = SidebarSelection.request(projectID: projectID, requestID: request.id)
            self.selection = target
            // Creating a request in a long tree otherwise puts it somewhere off
            // screen and silently swaps the editor to it.
            self.pendingScrollTarget = target
        }
    }

    func renameRequest(projectID: String, requestID: String, to name: String) async {
        await write {
            guard var request = try await self.requests.get(
                projectID: projectID, requestID: requestID
            ) else { return }
            request.name = name
            _ = try await self.requests.save(request)
            await self.reloadRequests(projectID: projectID)
            if self.editor.draft?.id == requestID { self.editor.draft?.name = name }
        }
    }

    func deleteRequest(projectID: String, requestID: String) async {
        await write {
            try await self.requests.delete(projectID: projectID, requestID: requestID)
            if self.selection?.requestID == requestID { self.selection = .project(projectID) }
            await self.reloadRequests(projectID: projectID)
        }
    }

    // MARK: - API documents

    /// Attaches a link and reads it straight away.
    ///
    /// A failed first read leaves the source attached rather than discarding it:
    /// the usual reason is a missing token, and throwing away what was typed
    /// would mean typing it again.
    func attachSpecLink(projectID: String, url: String, headers: [KeyValueItem]) async {
        var source = SpecSource(kind: .url)
        source.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        source.headers = headers
        await write { _ = try await self.projects.setSpecSource(source, for: projectID) }
        await reloadProjects()
        await syncSpec(projectID: projectID, using: .saved)
    }

    /// Re-reads the attached link. The manual refresh, and the only thing that
    /// triggers a sync of a link -- nothing re-reads it on its own.
    func updateSpecFromRemote(projectID: String) async {
        await syncSpec(projectID: projectID, using: .saved)
    }

    /// Takes a newly picked file through the identical merge path a link
    /// refresh uses, which is what makes re-uploading behave like updating.
    func replaceSpecFile(projectID: String, url: URL) async {
        if projectList.first(where: { $0.id == projectID })?.specSource == nil {
            await write {
                _ = try await self.projects.setSpecSource(SpecSource(kind: .file), for: projectID)
            }
        }
        await syncSpec(projectID: projectID, using: .file(url))
    }

    /// Saves edits to the source -- its URL and headers -- without syncing.
    func saveSpecSource(projectID: String, source: SpecSource) async {
        await write { _ = try await self.projects.setSpecSource(source, for: projectID) }
        await reloadProjects()
    }

    /// Drops the link and leaves every request exactly as it is, spec links
    /// included, so re-attaching the same document reconciles rather than
    /// duplicating.
    func detachSpec(projectID: String) async {
        await write { _ = try await self.projects.setSpecSource(nil, for: projectID) }
        await reloadProjects()
    }

    private func syncSpec(projectID: String, using source: SpecSyncService.Source) async {
        guard !isSyncingSpec else { return }
        isSyncingSpec = true
        defer { isSyncingSpec = false }

        // Commit whatever the autosave timer has not written yet: the sync reads
        // requests off disk, so a pending edit would be invisible to it and then
        // lost when the reload below replaces the draft.
        await editor.flushAutosave()

        do {
            // A sync writes requests and the project's own source, so the
            // project has to exist on disk before it runs.
            try await materializeProjectIfNeeded()
            let summary = try await specSync.sync(projectID: projectID, using: source)
            await reloadProjects()
            await reloadRequests(projectID: projectID)
            await reloadVariables(projectID: projectID)
            if summary.hasChanges { await reloadEditedRequest(in: projectID) }
            specSummary = SpecSyncSummary(result: summary)
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// Brings the open editor back in line with what the sync wrote, so the
    /// request on screen is not a stale copy of one that just changed.
    private func reloadEditedRequest(in projectID: String) async {
        guard case .request(let selected, let requestID)? = selection, selected == projectID
        else { return }
        await run {
            if let request = try await self.requests.get(
                projectID: projectID, requestID: requestID
            ) {
                self.editor.load(request)
            }
        }
    }

    /// Includes the recovery suggestion, so a message says what to do next
    /// rather than only what went wrong.
    private static func describe(_ error: any Error) -> String {
        guard let localized = error as? any LocalizedError else {
            return error.localizedDescription
        }
        return [localized.errorDescription ?? error.localizedDescription,
                localized.recoverySuggestion]
            .compactMap(\.self)
            .joined(separator: " ")
    }

    // MARK: - Folders

    /// The project's tree: folders, nested, with the requests in each.
    ///
    /// Built from the requests the sidebar would show, so filtering narrows the
    /// tree rather than sitting beside it -- a folder with no surviving request
    /// in it simply stops being drawn, unless the user made it by hand.
    var folderTree: FolderTree.Node {
        FolderTree.roots(
            requests: visibleRequests(in: projectID),
            declared: isFiltering ? [] : (project?.folders ?? [])
        )
    }

    /// The sidebar's rows, in the order it draws them.
    var sidebarRows: [FolderTree.Row] {
        FolderTree.flattened(folderTree) { isExpanded(folder: $0) }
    }

    /// Every folder that exists, for naming a new one and for validating a move.
    var allFolderPaths: Set<[String]> {
        FolderTree.allPaths(
            requests: requestsByProject[projectID] ?? [], declared: project?.folders ?? []
        )
    }

    /// While filtering, folders are forced open: a match hidden inside a
    /// collapsed folder would look like the filter had found nothing.
    func isExpanded(folder path: [String]) -> Bool {
        isFiltering || !collapsedFolders.contains(FolderTree.identifier(for: path))
    }

    /// Opens a folder and every folder above it, so a row inside it can be
    /// shown at all.
    func expand(folder path: [String]) {
        guard !path.isEmpty else { return }
        for depth in 1...path.count {
            collapsedFolders.remove(FolderTree.identifier(for: Array(path.prefix(depth))))
        }
    }

    func toggleExpansion(folder path: [String]) {
        let id = FolderTree.identifier(for: path)
        if collapsedFolders.contains(id) {
            collapsedFolders.remove(id)
        } else {
            collapsedFolders.insert(id)
        }
    }

    /// Makes a folder inside `parent`, named around whatever is already there.
    func createFolder(in parent: [String] = []) async {
        let name = FolderTree.availableName("New Folder", in: parent, among: allFolderPaths)
        await write {
            _ = try await self.projects.setFolders(
                (self.project?.folders ?? []) + [parent + [name]], for: self.projectID
            )
            await self.reloadProjects()
        }
    }

    /// Moves one request into a folder.
    func move(requestID: String, to folder: [String]) async {
        await write {
            guard try await self.requests.move(
                projectID: self.projectID, requestID: requestID, to: folder
            ) != nil else { return }
            await self.reloadRequests(projectID: self.projectID)
        }
    }

    /// Re-parents a folder, bringing its requests and subfolders with it.
    ///
    /// Refused when the destination is inside the folder being moved: that
    /// would cut the branch off from the tree, with no way to reach it again.
    func move(folder: [String], into parent: [String]) async {
        guard !FolderTree.isSelfOrDescendant(parent, of: folder),
              parent != Array(folder.dropLast())
        else { return }
        let destination = parent + [folder[folder.count - 1]]
        guard !allFolderPaths.contains(destination) else {
            errorMessage = "There is already a folder called “\(destination.last ?? "")” there."
            return
        }
        await rewriteFolder(from: folder, to: destination)
    }

    /// Renames a folder in place. Its descendants' paths move with it.
    func renameFolder(_ folder: [String], to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != folder.last else { return }
        let destination = Array(folder.dropLast()) + [trimmed]
        guard !allFolderPaths.contains(destination) else {
            errorMessage = "There is already a folder called “\(trimmed)” here."
            return
        }
        await rewriteFolder(from: folder, to: destination)
    }

    /// The one write behind both renaming and moving: every path under `from`
    /// is rewritten, on the requests and on the project's own list.
    private func rewriteFolder(from: [String], to destination: [String]) async {
        await write {
            try await self.requests.moveFolder(
                projectID: self.projectID, from: from, to: destination
            )
            let declared = (self.project?.folders ?? []).map {
                FolderTree.rewriting($0, from: from, to: destination) ?? $0
            }
            _ = try await self.projects.setFolders(declared, for: self.projectID)
            await self.reloadProjects()
            await self.reloadRequests(projectID: self.projectID)
        }
    }

    /// Deletes a folder and everything in it. Only ever reached from a
    /// confirmed delete -- nothing else here removes a request the user did not
    /// name.
    func deleteFolder(_ folder: [String]) async {
        await write {
            try await self.requests.deleteFolder(projectID: self.projectID, folder: folder)
            let declared = (self.project?.folders ?? []).filter {
                !FolderTree.isSelfOrDescendant($0, of: folder)
            }
            _ = try await self.projects.setFolders(declared, for: self.projectID)
            await self.reloadProjects()
            await self.reloadRequests(projectID: self.projectID)
            // The selected request may have been inside the folder.
            if let requestID = self.selection?.requestID,
               (self.requestsByProject[self.projectID] ?? [])
                   .first(where: { $0.id == requestID }) == nil {
                self.selection = .project(self.projectID)
            }
        }
    }

    // MARK: - Filtering

    /// Narrows the sidebar to matching requests as it is typed. Held in memory
    /// only: a filter is a thing you are doing right now, and coming back to a
    /// window that silently hides most of its requests would be alarming.
    var filterQuery = ""

    /// Bumped every time the shortcut is used, so the field takes focus even
    /// though it is always on screen and has nothing to open.
    private(set) var filterFocusRequests = 0

    var isFiltering: Bool { RequestFilter.normalized(filterQuery) != nil }

    func focusFilter() {
        filterFocusRequests += 1
    }

    func clearFilter() {
        filterQuery = ""
    }

    /// How many requests the filter is hiding, so the bar can say so rather
    /// than leaving an empty tree looking broken.
    var hiddenByFilterCount: Int {
        guard isFiltering else { return 0 }
        return allVisibleRequests.count - visibleRequests(in: projectID).count
    }

    // MARK: - Favorites

    /// Which sidebar list is on screen.
    ///
    /// Held in memory rather than remembered across launches, like the filter:
    /// which way you are looking at a project right now is not something a
    /// window should still be doing to you tomorrow.
    var sidebarTab: SidebarTab = .project

    /// The starred requests, in the order the project lists them.
    ///
    /// Built from `visibleRequests` rather than the raw list, so the filter
    /// field at the bottom of the sidebar narrows this tab exactly as it
    /// narrows the tree, and a removed endpoint stays hidden here too.
    var favoriteRequests: [APIRequest] {
        visibleRequests(in: projectID).filter(\.isFavorite)
    }

    /// Whether the Favorites tab has anything to show at all, ignoring the
    /// filter -- an empty tab needs to say which of the two emptinesses it is.
    var hasFavorites: Bool {
        allVisibleRequests.contains { $0.isFavorite }
    }

    func isFavorite(requestID: String) -> Bool {
        (requestsByProject[projectID] ?? []).first { $0.id == requestID }?.isFavorite == true
    }

    /// Stars or unstars one request, writing straight to its file.
    ///
    /// The open draft is patched too, the way a rename is: `save` writes the
    /// whole draft, so a draft still carrying the old flag would undo this the
    /// next time autosave ran.
    func toggleFavorite(projectID: String, requestID: String) async {
        let starred = !isFavorite(requestID: requestID)
        await write {
            guard try await self.requests.setFavorite(
                projectID: projectID, requestID: requestID, starred
            ) != nil else { return }
            if self.editor.draft?.id == requestID { self.editor.draft?.isFavorite = starred }
            await self.reloadRequests(projectID: projectID)
        }
    }

    /// The request the Favorites menu command acts on: whatever is selected.
    var selectedRequestID: String? { selection?.requestID }

    // MARK: - Global headers

    /// Replaces the headers every request in the project inherits.
    func setProjectHeaders(_ headers: [KeyValueItem], for projectID: String) async {
        await write {
            _ = try await self.projects.setGlobalHeaders(headers, for: projectID)
            await self.reloadProjects()
        }
    }

    // MARK: - Variables

    func setVariable(projectID: String, key: String, value: String) async {
        await write {
            try await self.variables.setOne(projectID: projectID, key: key, value: value)
            await self.reloadVariables(projectID: projectID)
        }
    }

    func deleteVariable(projectID: String, key: String) async {
        await write {
            try await self.variables.delete(projectID: projectID, key: key)
            await self.reloadVariables(projectID: projectID)
        }
    }

    /// The project a new request lands in: the window's, always.
    var targetProjectIDForNewRequest: String? { projectID }

    /// The folder a new request lands in: the selected folder, or the folder of
    /// the selected request, or the top level.
    ///
    /// Reading it off the selection rather than tracking a "current folder"
    /// means there is only ever one answer to "where am I", and it is the one
    /// the sidebar is already highlighting.
    var targetFolderForNewRequest: [String] {
        guard let selection else { return [] }
        if let path = selection.folderPath { return path }
        guard let requestID = selection.requestID else { return [] }
        return (requestsByProject[projectID] ?? [])
            .first { $0.id == requestID }?.folder ?? []
    }

    private func run(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Every action that changes something goes through here rather than
    /// `run`, so a project held unsaved is written exactly once, on the first
    /// change, before whatever asked for that change happens.
    ///
    /// Split from `run` rather than folded into it: reloading is not a change,
    /// and materialising on a read would write the very projects this is meant
    /// to keep off disk.
    private func write(_ work: () async throws -> Void) async {
        do {
            try await materializeProjectIfNeeded()
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Writes a project that until now existed only in memory.
    private func materializeProjectIfNeeded() async throws {
        guard let project = unsavedProject else { return }
        unsavedProject = nil
        try await projects.create(project)
        await reloadProjects()
    }
}
