import Foundation

/// Which list the sidebar is showing -- the project's tree, or the requests
/// starred out of it.
///
/// The tab strip is Xcode's navigator idea: one sidebar, several ways of
/// looking at the same project, rather than a second pane to find room for.
enum SidebarTab: String, CaseIterable, Identifiable, Sendable {
    case project
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .project: "Project"
        case .favorites: "Favorites"
        }
    }

    /// Filled while selected, outline otherwise -- the same pairing the rest of
    /// the app uses for the filter icon.
    func symbol(isSelected: Bool) -> String {
        switch self {
        case .project: isSelected ? "folder.fill" : "folder"
        case .favorites: isSelected ? "bookmark.fill" : "bookmark"
        }
    }
}
