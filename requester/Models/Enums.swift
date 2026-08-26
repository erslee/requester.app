import Foundation

/// The HTTP verbs the editor offers. Raw values are the wire method names.
nonisolated enum HTTPMethod: String, Codable, Sendable, CaseIterable, Identifiable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"

    var id: String { rawValue }
}

nonisolated enum BodyMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    case raw
    case form
    case graphQL

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .raw: "Raw"
        case .form: "Form"
        case .graphQL: "GraphQL"
        }
    }
}

nonisolated enum RawBodyType: String, Codable, Sendable, CaseIterable, Identifiable {
    case text
    case json
    case xml

    var id: String { rawValue }
}

nonisolated enum AuthType: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    case basic
    case bearer
    case apiKey

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "No Auth"
        case .basic: "Basic"
        case .bearer: "Bearer Token"
        case .apiKey: "API Key"
        }
    }
}

nonisolated enum APIKeyLocation: String, Codable, Sendable, CaseIterable, Identifiable {
    case header
    case query

    var id: String { rawValue }
}

/// Whether a variable's current value was typed by the user or written by a
/// post-response script. Surfaced in the variables table so a value that
/// appears out of nowhere is traceable to the request that set it.
nonisolated enum VariableSource: String, Codable, Sendable {
    case manual
    case script
}
