import Foundation

/// Which list the sidebar is showing -- the project's tree, the requests
/// starred out of it, or the ones most recently sent.
///
/// The tab strip is Xcode's navigator idea: one sidebar, several ways of
/// looking at the same project, rather than a second pane to find room for.
enum SidebarTab: String, CaseIterable, Identifiable, Sendable {
    case project
    case favorites
    case history

    var id: String { rawValue }

    /// What the tab is tooltipped and announced by.
    ///
    /// "Project" on its own is deliberately avoided: the sidebar used to carry
    /// a New Project button with that accessibility label, and the UI tests
    /// assert its absence by that label -- a tab answering to it would read as
    /// the button coming back.
    var navigatorName: String {
        switch self {
        case .project: "Project Navigator"
        case .favorites: "Favorites Navigator"
        case .history: "History Navigator"
        }
    }

    /// Filled while selected, outline otherwise -- the same pairing the rest of
    /// the app uses for the filter icon.
    func symbol(isSelected: Bool) -> String {
        switch self {
        case .project: isSelected ? "folder.fill" : "folder"
        case .favorites: isSelected ? "bookmark.fill" : "bookmark"
        case .history: isSelected ? "clock.fill" : "clock"
        }
    }
}
