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
    @State private var deleteFolderTarget: [String]?
    @FocusState private var isFilterFocused: Bool

    var body: some View {
        // The reader is what brings a newly created request on screen;
        // `scrollTo` needs the rows to carry ids, which mirror their tags.
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                tabStrip
                Divider()
                lists
            }
            .onChange(of: model.pendingScrollTarget) { _, target in
                guard let target else { return }
                // A row can only be scrolled to on the tab that draws it, and
                // the only thing that scrolls is a newly created request.
                model.sidebarTab = .project
                withAnimation { proxy.scrollTo(target, anchor: .center) }
                model.pendingScrollTarget = nil
            }
        }
    }

    /// Whichever tab is showing, under the shared bottom bar -- the new-request
    /// button and the filter belong to the sidebar, not to one list.
    ///
    /// Both lists are built and kept, with the one not in front hidden rather
    /// than removed. A `switch` here would destroy the scroll view holding the
    /// offset, so coming back to a tab would land at the top of it; hiding
    /// leaves AppKit to keep each list exactly where it was left.
    @ViewBuilder
    private var lists: some View {
        ZStack {
            tab(.project) { list }
            tab(.favorites) { favoritesList }
        }
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
        .confirmationDialog(
            "Delete this folder and every request in it?",
            isPresented: .init(
                get: { deleteFolderTarget != nil },
                set: { if !$0 { deleteFolderTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let folder = deleteFolderTarget else { return }
                deleteFolderTarget = nil
                Task { await model.deleteFolder(folder) }
            }
            Button("Cancel", role: .cancel) { deleteFolderTarget = nil }
        }
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.projectList) { project in
                rows(for: project)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Tabs

    /// Xcode's navigator strip: one sidebar, a row of icons deciding what it
    /// lists. Two tabs today -- the project's tree, and what has been starred
    /// out of it.
    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(SidebarTab.allCases) { tab in
                let isSelected = model.sidebarTab == tab
                Button {
                    model.sidebarTab = tab
                } label: {
                    Image(systemName: tab.symbol(isSelected: isSelected))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                    }
                }
                .help(tab.navigatorName)
                .accessibilityLabel(tab.navigatorName)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }

    /// One tab's list, shown or held out of the way.
    ///
    /// Hidden all three ways it has to be: invisible, untouchable, and out of
    /// the accessibility tree -- a list that still answered to VoiceOver or to
    /// a UI test query would make every request in the window appear twice.
    @ViewBuilder
    private func tab(_ which: SidebarTab, @ViewBuilder content: () -> some View) -> some View {
        let isShowing = model.sidebarTab == which
        content()
            .opacity(isShowing ? 1 : 0)
            .allowsHitTesting(isShowing)
            .accessibilityHidden(!isShowing)
    }

    /// Starred requests, flat and in project order -- a jump list rather than a
    /// second tree. Where each one is filed is written beside it, since the
    /// folder it sits in is the context the tree would have given.
    private var favoritesList: some View {
        List(selection: $model.selection) {
            ForEach(model.favoriteRequests) { request in
                let tag = SidebarSelection.request(
                    projectID: model.projectID, requestID: request.id
                )
                requestRow(request, in: model.projectID, inFavoritesTab: true)
                    .tag(tag)
                    .id(tag)
                    .contextMenu {
                        requestMenu(projectID: model.projectID, requestID: request.id)
                    }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.favoriteRequests.isEmpty { favoritesPlaceholder }
        }
    }

    /// An empty tab has to say which emptiness it is: nothing starred yet, or
    /// everything starred hidden by what is typed in the filter.
    private var favoritesPlaceholder: some View {
        ContentUnavailableView {
            Label("No Favorites", systemImage: "bookmark")
        } description: {
            Text(
                model.hasFavorites
                    ? "No favorite matches the filter."
                    : "Right-click a request and choose Add to Favorites."
            )
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
                    let folder = model.targetFolderForNewRequest
                    Task { await model.createRequest(projectID: projectID, folder: folder) }
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
            // The project row is the drop target for "out of every folder".
            .dropDestination(for: SidebarDrag.self) { items, _ in
                drop(items, into: [])
            }

        if model.isExpanded(project.id) {
            // Depth is drawn with indentation rather than nested containers: a
            // `List` with selection wants one flat sequence of rows, so the
            // tree is walked in `FolderTree.flattened` before it gets here.
            ForEach(model.sidebarRows) { row in
                switch row {
                case .folder(let node):
                    let folderTag = SidebarSelection.folder(
                        projectID: project.id, path: node.path
                    )
                    folderRow(node)
                        .tag(folderTag)
                        .id(folderTag)
                case .request(let request, let depth):
                    let tag = SidebarSelection.request(
                        projectID: project.id, requestID: request.id
                    )
                    requestRow(request, in: project.id, depth: depth)
                        .tag(tag)
                        .id(tag)
                        .contextMenu {
                            requestMenu(projectID: project.id, requestID: request.id)
                        }
                        .draggable(SidebarDrag.request(request.id))
                }
            }
        }
    }

    private func folderRow(_ node: FolderTree.Node) -> some View {
        let isExpanded = model.isExpanded(folder: node.path)

        return HStack(spacing: 4) {
            // Only the triangle opens the folder; the row itself selects, the
            // way Finder and Xcode behave. A row that did both would make a
            // folder impossible to select without also opening or closing it.
            Button {
                model.toggleExpansion(folder: node.path)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(node.name)" : "Expand \(node.name)")

            // Filled and tinted, whatever the disclosure state -- the way
            // Xcode's navigator draws them. The chevron beside it already says
            // open or closed, so the icon swapping too was saying it twice.
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)

            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .padding(.leading, CGFloat(node.path.count - 1) * 14 + 20)
        .contextMenu { folderMenu(node) }
        .draggable(SidebarDrag.folder(node.path))
        .dropDestination(for: SidebarDrag.self) { items, _ in
            drop(items, into: node.path)
        }
    }

    @ViewBuilder
    private func folderMenu(_ node: FolderTree.Node) -> some View {
        Button("New Request") {
            Task { await model.createRequest(projectID: model.projectID, folder: node.path) }
        }
        Button("New Folder") {
            Task { await model.createFolder(in: node.path) }
        }
        Divider()
        Button("Rename Folder…") {
            renameTarget = .folder(node.path)
            renameText = node.name
        }
        Button("Delete Folder…", role: .destructive) {
            deleteFolderTarget = node.path
        }
    }

    /// Applies a drop, whatever was dragged. Returns whether anything was taken,
    /// which is what tells the system to show the move as accepted.
    private func drop(_ items: [SidebarDrag], into folder: [String]) -> Bool {
        var accepted = false
        for item in items {
            switch item {
            case .request(let requestID):
                accepted = true
                Task { await model.move(requestID: requestID, to: folder) }
            case .folder(let path):
                // Refused rather than silently ignored further down: a folder
                // dropped into itself would take the branch out of the tree.
                guard !FolderTree.isSelfOrDescendant(folder, of: path) else { continue }
                accepted = true
                Task { await model.move(folder: path, into: folder) }
            }
        }
        return accepted
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

            // The root reads as the root: same tint as its folders, a
            // different glyph.
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(.tint)

            Text(project.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    /// One request row, on either tab. The Favorites tab draws the same row
    /// with where the request is filed written after it -- on the Project tab
    /// the tree already says that, and a star says what the tab itself says.
    private func requestRow(
        _ request: APIRequest, in projectID: String, depth: Int = 0,
        inFavoritesTab: Bool = false
    ) -> some View {
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

            if request.isFavorite && !inFavoritesTab {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tint)
                    .help("A favorite")
            }

            if inFavoritesTab && !request.folder.isEmpty {
                Spacer(minLength: 8)
                // Truncated from the front: the folder a request sits *in* is
                // the end of its path, which is the half worth keeping.
                Text(request.folder.joined(separator: " ▸ "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        // Dimmed rather than disabled: the endpoint is gone from the document,
        // but the request is still entirely usable -- open it, edit it, send it,
        // read its history.
        .opacity(isRemoved ? 0.55 : 1)
        .help(isRemoved ? removedHelp(request) : "")
        .padding(.vertical, 2)
        .padding(.leading, CGFloat(depth) * 14 + 20)
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
        Button("New Folder") { Task { await model.createFolder() } }
        Divider()
        Button("Rename Project…") { renameTarget = .project(projectID) }
        Button("Delete Project…", role: .destructive) {
            deleteTarget = .project(projectID)
        }
    }

    @ViewBuilder
    private func requestMenu(projectID: String, requestID: String) -> some View {
        let isFavorite = model.isFavorite(requestID: requestID)
        Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            Task { await model.toggleFavorite(projectID: projectID, requestID: requestID) }
        }
        Divider()
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
        // Folders are confirmed by their own dialog, which knows the path.
        case .folder, nil: ""
        }
    }

    private func rename(_ target: RenameTarget, to newName: String) async {
        switch target {
        case .project(let projectID):
            await model.renameProject(projectID, to: newName)
        case .request(let projectID, let requestID):
            await model.renameRequest(projectID: projectID, requestID: requestID, to: newName)
        case .folder(let path):
            await model.renameFolder(path, to: newName)
        }
    }

    private func delete(_ target: SidebarSelection) async {
        switch target {
        case .project(let projectID):
            await model.deleteProject(projectID)
        case .request(let projectID, let requestID):
            await model.deleteRequest(projectID: projectID, requestID: requestID)
        case .folder(_, let path):
            await model.deleteFolder(path)
        }
    }
}

/// What the rename alert is editing.
enum RenameTarget: Identifiable {
    case project(String)
    case request(projectID: String, requestID: String)
    case folder([String])

    var id: String {
        switch self {
        case .project(let id): "project-\(id)"
        case .request(_, let requestID): "request-\(requestID)"
        case .folder(let path): "folder-\(FolderTree.identifier(for: path))"
        }
    }
}

/// What a sidebar row carries while being dragged.
///
/// One type for both, so a folder and a request can be dropped on the same
/// targets and the drop decides what to do with what it got.
nonisolated enum SidebarDrag: Codable, Transferable {
    case request(String)
    case folder([String])

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .requesterSidebarRow)
    }
}

nonisolated extension UTType {
    /// Private to this app: a row dragged out of the sidebar means nothing
    /// anywhere else, and a public type would invite other apps to accept it.
    static let requesterSidebarRow = UTType(exportedAs: "dev.requester.sidebar-row")
}
