import Foundation

/// Remembers how one project's window was left: whether its row was collapsed,
/// and what was selected inside it.
///
/// Scoped to a project id, because a window is scoped to a project -- two
/// windows must not overwrite each other's selection, and reopening a project
/// should come back to where that project was left rather than wherever the
/// last window happened to be.
///
/// Kept in `UserDefaults` rather than in the data folder. The folder holds
/// request definitions meant to be shared or committed; which rows one person
/// had folded is per-machine interface state and has no business travelling
/// with them.
@MainActor
final class InterfaceStateStore {
    private let projectID: String
    private let defaults: UserDefaults

    init(projectID: String, defaults: UserDefaults = .standard) {
        self.projectID = projectID
        self.defaults = defaults
    }

    /// Per-project keys. The project id is part of the key rather than part of
    /// a stored blob, so forgetting one project's state never rewrites another's.
    private func key(_ name: String) -> String { "sidebar.\(projectID).\(name)" }

    /// Collapsed rather than expanded is stored, so the default -- a `false`
    /// from `UserDefaults` for a project never opened -- is expanded.
    var isProjectCollapsed: Bool {
        get { defaults.bool(forKey: key("collapsed")) }
        set {
            guard newValue else {
                defaults.removeObject(forKey: key("collapsed"))
                return
            }
            defaults.set(true, forKey: key("collapsed"))
        }
    }

    /// Whether endpoints a spec has dropped are listed. Off by default: the
    /// common case is wanting the sidebar to match the document, with the
    /// removed ones a deliberate look rather than permanent clutter.
    ///
    /// Deliberately *not* per project: it reads as a preference about how the
    /// app behaves, not as something to re-decide in every window.
    var showsRemovedEndpoints: Bool {
        get { defaults.bool(forKey: Self.showsRemovedKey) }
        set { defaults.set(newValue, forKey: Self.showsRemovedKey) }
    }

    private static let showsRemovedKey = "sidebarShowsRemovedEndpoints"

    var selection: SidebarSelection? {
        get {
            guard let data = defaults.data(forKey: key("selection")) else { return nil }
            return try? JSONDecoder().decode(SidebarSelection.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: key("selection"))
                return
            }
            defaults.set(data, forKey: key("selection"))
        }
    }

    /// Folders the user has collapsed, by full path. Collapsed rather than
    /// expanded, so a folder that appears from an import is open by default and
    /// its contents are visible without hunting for them.
    var collapsedFolders: Set<String> {
        get { Set(defaults.stringArray(forKey: key("collapsedFolders")) ?? []) }
        set {
            guard !newValue.isEmpty else {
                defaults.removeObject(forKey: key("collapsedFolders"))
                return
            }
            defaults.set(newValue.sorted(), forKey: key("collapsedFolders"))
        }
    }

    /// Drops everything remembered about a project, for when it is deleted.
    func forgetProject() {
        defaults.removeObject(forKey: key("collapsed"))
        defaults.removeObject(forKey: key("collapsedFolders"))
        defaults.removeObject(forKey: key("selection"))
    }
}
