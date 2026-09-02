import Foundation

/// Remembers which projects were opened, most recent first, so the launcher can
/// offer them without the user hunting through every project they ever made.
///
/// Only ids are stored. Names live in `project.json` and are read from the
/// repository when the list is shown -- keeping a copy here would mean a
/// renamed project reading one way in its window and another in the launcher.
///
/// In `UserDefaults` rather than the data folder, for the same reason as
/// `InterfaceStateStore`: which projects *this* person opened recently is
/// per-machine interface state, and has no business travelling with a data
/// folder that is meant to be shared or committed.
@MainActor
final class RecentProjectsStore {
    private static let key = "recentProjectIDs"

    /// How many openings are worth remembering. The launcher lists every
    /// project, so this decides only how far down the list recency reaches:
    /// the most recent few lead, and everything past this falls back to
    /// alphabetical order -- which is where the search field takes over.
    static let limit = 8

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Most recently opened first.
    var projectIDs: [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    /// Moves a project to the front, whether or not it was already listed, so
    /// re-opening one reorders rather than duplicating it.
    func markOpened(_ projectID: String) {
        var ids = projectIDs.filter { $0 != projectID }
        ids.insert(projectID, at: 0)
        defaults.set(Array(ids.prefix(Self.limit)), forKey: Self.key)
    }

    /// Drops a project from the list -- when it is deleted, or when it is found
    /// to be gone from the data folder.
    func forget(_ projectID: String) {
        let ids = projectIDs.filter { $0 != projectID }
        guard !ids.isEmpty else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        defaults.set(ids, forKey: Self.key)
    }
}
