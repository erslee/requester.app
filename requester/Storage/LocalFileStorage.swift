import Foundation

/// Local filesystem `StorageBackend`, serialized on an actor so concurrent
/// sends appending to the same history file cannot interleave partial lines.
actor LocalFileStorage: StorageBackend {
    private let root: URL
    private let fileManager = FileManager.default

    init(root: URL) throws {
        self.root = root
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func url(for path: String) -> URL {
        root.appending(path: path, directoryHint: .notDirectory)
    }

    func readText(at path: String) throws -> String? {
        let url = url(for: path)
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func writeText(_ text: String, to path: String) throws {
        let url = url(for: path)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    func appendLine(_ line: String, to path: String) throws {
        let url = url(for: path)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let payload = Data((line.trimmingCharacters(in: .newlines) + "\n").utf8)

        guard let handle = FileHandle(forWritingAtPath: url.path(percentEncoded: false)) else {
            try payload.write(to: url, options: .atomic)
            return
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
    }

    func listDirectory(at path: String) throws -> [String] {
        let url = url(for: path)
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return [] }
        return try fileManager.contentsOfDirectory(atPath: url.path(percentEncoded: false)).sorted()
    }

    func exists(at path: String) -> Bool {
        fileManager.fileExists(atPath: url(for: path).path(percentEncoded: false))
    }

    func delete(at path: String) throws {
        let url = url(for: path)
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try fileManager.removeItem(at: url)
    }

    func deleteTree(at path: String) throws {
        try delete(at: path)
    }
}
