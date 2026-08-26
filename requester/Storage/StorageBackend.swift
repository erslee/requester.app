import Foundation

/// Abstract storage, so a future remote backend (e.g. Google Drive) can be
/// swapped in without touching repositories, domain, or views.
nonisolated protocol StorageBackend: Sendable {
    /// The file's contents, or `nil` if it does not exist.
    func readText(at path: String) async throws -> String?

    /// Write atomically (temp file + replace) so a crash mid-write cannot
    /// leave a half-written project or request behind.
    func writeText(_ text: String, to path: String) async throws

    /// Append one line, creating the file and its parents if needed.
    func appendLine(_ line: String, to path: String) async throws

    /// Names of entries directly under a directory; empty if it does not exist.
    func listDirectory(at path: String) async throws -> [String]

    func exists(at path: String) async -> Bool
    func delete(at path: String) async throws

    /// Recursively delete a directory and everything under it, if present.
    func deleteTree(at path: String) async throws
}

extension StorageBackend {
    func readModel<T: Decodable & Sendable>(_ type: T.Type, at path: String) async throws -> T? {
        guard let text = try await readText(at: path), let data = text.data(using: .utf8) else {
            return nil
        }
        return try JSONCoding.decoder.decode(type, from: data)
    }

    func writeModel(_ model: some Encodable & Sendable, to path: String) async throws {
        let data = try JSONCoding.prettyEncoder.encode(model)
        try await writeText(String(decoding: data, as: UTF8.self), to: path)
    }

    func appendModelLine(_ model: some Encodable & Sendable, to path: String) async throws {
        let data = try JSONCoding.compactEncoder.encode(model)
        try await appendLine(String(decoding: data, as: UTF8.self), to: path)
    }
}
