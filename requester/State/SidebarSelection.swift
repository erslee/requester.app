import Foundation

/// What the sidebar has selected. A project shows its detail view; a request
/// opens the editor.
enum SidebarSelection: Hashable, Codable, Sendable {
    case project(String)
    case request(projectID: String, requestID: String)

    var projectID: String {
        switch self {
        case .project(let id): id
        case .request(let projectID, _): projectID
        }
    }

    var requestID: String? {
        switch self {
        case .project: nil
        case .request(_, let requestID): requestID
        }
    }
}
