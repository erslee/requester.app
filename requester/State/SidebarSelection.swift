import Foundation

/// What the sidebar has selected. A project shows its detail view, a folder
/// shows what is in it, and a request opens the editor.
enum SidebarSelection: Hashable, Codable, Sendable {
    case project(String)
    case folder(projectID: String, path: [String])
    case request(projectID: String, requestID: String)

    var projectID: String {
        switch self {
        case .project(let id): id
        case .folder(let projectID, _): projectID
        case .request(let projectID, _): projectID
        }
    }

    var requestID: String? {
        switch self {
        case .project, .folder: nil
        case .request(_, let requestID): requestID
        }
    }

    /// The folder this selection is in or is: a folder is its own, a request is
    /// wherever it was filed -- which the caller has to supply, since only the
    /// request itself knows. `nil` for the project row, meaning top level.
    var folderPath: [String]? {
        switch self {
        case .project, .request: nil
        case .folder(_, let path): path
        }
    }
}
