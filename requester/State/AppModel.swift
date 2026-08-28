import Foundation

/// Root observable state: the wired dependency graph, the project/request tree
/// behind the sidebar, each project's variables, and the current selection.
///
/// Replaces the Qt controllers and their signals -- observation handles the
/// change notification that `projects_changed` / `requests_changed` /
/// `variables_changed` used to carry by hand.
@MainActor
@Observable
final class AppModel {
    let projects: ProjectRepository
    let requests: RequestRepository
    let variables: VariableRepository
    let history: HistoryRepository

    let editor: EditorModel
    let historyPanel: HistoryModel
    let specSync: SpecSyncService

    var projectList: [Project] = []
    var requestsByProject: [String: [APIRequest]] = [:]
    var variablesByProject: [String: [String: Variable]] = [:]

    var selection: SidebarSelection? {
        didSet {
            interfaceState.selection = selection
            handleSelectionChange(from: oldValue)
        }
    }

    /// Surfaced as an alert. A failed read or write should say so rather than
    /// vanish into the console.
    var errorMessage: String?

    /// Shown after an import, so what did and did not come across is visible.
    var importSummary: ImportSummary?

    /// Whether the file picker is open, kept separate from whether an import is
    /// running -- sharing one flag would have the picker reopen itself the
    /// moment the import finished.
    var isChoosingImportFile = false
    var isImporting = false

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

    struct ImportSummary: Identifiable {
        let id = UUID()
        var collectionName: String
        var requestCount: Int
        var variableCount: Int
        var warnings: [String]
        var scriptsNeedingReview: [String]
    }

    private let interfaceState: InterfaceStateStore

    init(storage: any StorageBackend, interfaceState: InterfaceStateStore = InterfaceStateStore()) {
        self.interfaceState = interfaceState
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
        for project in projectList {
            await reloadRequests(projectID: project.id)
        }
        restoreInterfaceState()
    }

    /// Brings the sidebar back as it was left.
    ///
    /// Everything is checked against what actually exists first: the data folder
    /// may have been changed, or a project deleted from another window, and a
    /// selection pointing at something gone would leave the app on a blank
    /// pane with no way back.
    private func restoreInterfaceState() {
        let existingProjects = Set(projectList.map(\.id))
        // Assigning the intersection also prunes ids that are no longer real.
        collapsedProjectIDs = interfaceState.collapsedProjectIDs
            .intersection(existingProjects)

        guard let saved = interfaceState.selection,
              existingProjects.contains(saved.projectID)
        else {
            interfaceState.selection = nil
            return
        }

        guard let requestID = saved.requestID else {
            selection = saved
            return
        }

        // The request may have gone while the project remains; falling back to
        // the project is closer to where the user was than nothing at all.
        let stillExists = (requestsByProject[saved.projectID] ?? [])
            .contains { $0.id == requestID }
        selection = stillExists ? saved : .project(saved.projectID)
    }

    func reloadProjects() async {
        await run { self.projectList = try await self.projects.listAll() }
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

    /// Collapsed rather than expanded ids are tracked, so a project is expanded
    /// by default and a newly loaded one does not appear empty.
    private var collapsedProjectIDs: Set<String> = [] {
        didSet { interfaceState.collapsedProjectIDs = collapsedProjectIDs }
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

    /// The rows the sidebar shows for a project.
    func visibleRequests(in projectID: String) -> [APIRequest] {
        let all = requestsByProject[projectID] ?? []
        guard !showsRemovedEndpoints else { return all }
        return all.filter { $0.spec?.isRemoved != true }
    }

    /// How many are hidden right now, so the toggle can say what it would reveal.
    func removedRequestCount(in projectID: String) -> Int {
        (requestsByProject[projectID] ?? []).count { $0.spec?.isRemoved == true }
    }

    func isExpanded(_ projectID: String) -> Bool {
        !collapsedProjectIDs.contains(projectID)
    }

    func toggleExpansion(_ projectID: String) {
        if collapsedProjectIDs.contains(projectID) {
            collapsedProjectIDs.remove(projectID)
        } else {
            collapsedProjectIDs.insert(projectID)
        }
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
        collapsedProjectIDs.remove(entry.projectID)

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

    func createProject(name: String) async {
        await run {
            let project = try await self.projects.create(name: name)
            await self.reloadProjects()
            self.selection = .project(project.id)
        }
    }

    func renameProject(_ projectID: String, to name: String) async {
        await run {
            _ = try await self.projects.rename(projectID, to: name)
            await self.reloadProjects()
        }
    }

    func deleteProject(_ projectID: String) async {
        await run {
            try await self.projects.delete(projectID)
            self.requestsByProject[projectID] = nil
            self.variablesByProject[projectID] = nil
            self.collapsedProjectIDs.remove(projectID)
            if self.selection?.projectID == projectID { self.selection = nil }
            await self.reloadProjects()
        }
    }

    func createRequest(projectID: String) async {
        await run {
            let request = try await self.requests.create(projectID: projectID)
            // Expand first: a row inside a collapsed project cannot be selected,
            // and the List would snap the selection back.
            self.collapsedProjectIDs.remove(projectID)
            await self.reloadRequests(projectID: projectID)
            self.selection = .request(projectID: projectID, requestID: request.id)
        }
    }

    func renameRequest(projectID: String, requestID: String, to name: String) async {
        await run {
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
        await run {
            try await self.requests.delete(projectID: projectID, requestID: requestID)
            if self.selection?.requestID == requestID { self.selection = .project(projectID) }
            await self.reloadRequests(projectID: projectID)
        }
    }

    // MARK: - Import

    /// Imports a Postman collection as a new project.
    ///
    /// The whole collection lands in one project: Postman folders have no
    /// equivalent here, so their names are folded into the request names.
    func importPostmanCollection(from url: URL) async {
        isImporting = true
        defer { isImporting = false }

        // A file chosen through the importer is security-scoped, and reading it
        // without taking that scope fails under the sandbox.
        let hasScope = url.startAccessingSecurityScopedResource()
        defer { if hasScope { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            let collection = try PostmanImporter.collection(from: data)

            let project = try await projects.create(name: collection.name)
            try await variables.setMany(
                projectID: project.id, writes: collection.variables, source: .manual
            )

            for imported in collection.requests {
                var request = try await requests.create(projectID: project.id)
                let id = request.id
                request = imported
                request.id = id
                request.projectID = project.id
                _ = try await requests.save(request)
            }

            await reloadProjects()
            await reloadRequests(projectID: project.id)
            selection = .project(project.id)

            importSummary = ImportSummary(
                collectionName: collection.name,
                requestCount: collection.requests.count,
                variableCount: collection.variables.count,
                warnings: collection.warnings,
                scriptsNeedingReview: collection.scriptsNeedingReview
            )
        } catch {
            errorMessage = Self.describe(error)
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
        await run { _ = try await self.projects.setSpecSource(source, for: projectID) }
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
            await run {
                _ = try await self.projects.setSpecSource(SpecSource(kind: .file), for: projectID)
            }
        }
        await syncSpec(projectID: projectID, using: .file(url))
    }

    /// Saves edits to the source -- its URL and headers -- without syncing.
    func saveSpecSource(projectID: String, source: SpecSource) async {
        await run { _ = try await self.projects.setSpecSource(source, for: projectID) }
        await reloadProjects()
    }

    /// Drops the link and leaves every request exactly as it is, spec links
    /// included, so re-attaching the same document reconciles rather than
    /// duplicating.
    func detachSpec(projectID: String) async {
        await run { _ = try await self.projects.setSpecSource(nil, for: projectID) }
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

    // MARK: - Global headers

    /// Replaces the headers every request in the project inherits.
    func setProjectHeaders(_ headers: [KeyValueItem], for projectID: String) async {
        await run {
            _ = try await self.projects.setGlobalHeaders(headers, for: projectID)
            await self.reloadProjects()
        }
    }

    // MARK: - Variables

    func setVariable(projectID: String, key: String, value: String) async {
        await run {
            try await self.variables.setOne(projectID: projectID, key: key, value: value)
            await self.reloadVariables(projectID: projectID)
        }
    }

    func deleteVariable(projectID: String, key: String) async {
        await run {
            try await self.variables.delete(projectID: projectID, key: key)
            await self.reloadVariables(projectID: projectID)
        }
    }

    /// The project a new request should land in: the selected project, or the
    /// parent of the selected request.
    var targetProjectIDForNewRequest: String? { selection?.projectID }

    private func run(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
