import Foundation

/// Remembers how the sidebar was left: which projects were collapsed, and what
/// was selected.
///
/// Kept in `UserDefaults` rather than in the data folder. The folder holds
/// request definitions meant to be shared or committed; which rows one person
/// had folded is per-machine interface state and has no business travelling
/// with them.
@MainActor
final class InterfaceStateStore {
    private enum Key {
        static let collapsedProjects = "sidebarCollapsedProjectIDs"
        static let selection = "sidebarSelection"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var collapsedProjectIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.collapsedProjects) ?? []) }
        set {
            guard !newValue.isEmpty else {
                defaults.removeObject(forKey: Key.collapsedProjects)
                return
            }
            defaults.set(newValue.sorted(), forKey: Key.collapsedProjects)
        }
    }

    var selection: SidebarSelection? {
        get {
            guard let data = defaults.data(forKey: Key.selection) else { return nil }
            return try? JSONDecoder().decode(SidebarSelection.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Key.selection)
                return
            }
            defaults.set(data, forKey: Key.selection)
        }
    }
}
