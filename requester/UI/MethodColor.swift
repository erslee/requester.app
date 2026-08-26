import SwiftUI

extension HTTPMethod {
    /// Shared method colouring, used by the sidebar badges, the method picker,
    /// and the history rows so one verb always reads the same everywhere.
    var color: Color {
        switch self {
        case .get: Color(red: 0.18, green: 0.55, blue: 0.34)
        case .post: Color(red: 0.80, green: 0.48, blue: 0.00)
        case .put: Color(red: 0.19, green: 0.47, blue: 0.78)
        case .patch: Color(red: 0.55, green: 0.36, blue: 0.96)
        case .delete: Color(red: 0.86, green: 0.15, blue: 0.15)
        case .head, .options: Color.secondary
        }
    }
}

extension ResponseRecord {
    var statusColor: Color {
        switch statusCode {
        case ..<300: Color(red: 0.18, green: 0.55, blue: 0.34)
        case ..<400: Color(red: 0.19, green: 0.47, blue: 0.78)
        case ..<500: Color(red: 0.80, green: 0.48, blue: 0.00)
        default: Color(red: 0.86, green: 0.15, blue: 0.15)
        }
    }
}

/// The colours syntax highlighting and variable tinting share.
nonisolated enum Palette {
    static let valid = Color(red: 0.18, green: 0.55, blue: 0.34)
    static let invalid = Color(red: 0.86, green: 0.15, blue: 0.15)
    static let jsonKey = Color(red: 0.19, green: 0.47, blue: 0.78)
    static let jsonNumber = Color(red: 0.80, green: 0.48, blue: 0.00)
    static let jsonKeyword = Color(red: 0.55, green: 0.36, blue: 0.96)
}
