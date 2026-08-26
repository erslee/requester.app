import Foundation

/// Decides where the app's data lives.
///
/// By default that is the standard per-app support folder, which needs no
/// permission and no prompt. A user who wants their data somewhere else -- a
/// synced folder, a git repository -- can point the app at one, and that choice
/// is remembered as a security-scoped bookmark, since the app is sandboxed and
/// a plain path is not enough to reopen a folder after a relaunch.
@MainActor
final class StorageRootStore {
    private static let bookmarkKey = "storageRootBookmark"
    private static let folderName = "Requester"

    private let defaults: UserDefaults
    private var accessedURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The built-in location: `Application Support/Requester`, which inside the
    /// sandbox resolves into the app's own container.
    var defaultRoot: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")

        return support.appending(path: Self.folderName, directoryHint: .isDirectory)
    }

    var isUsingDefaultRoot: Bool {
        defaults.data(forKey: Self.bookmarkKey) == nil
    }

    /// The folder to open at launch: the user's own choice if they made one and
    /// it is still reachable, otherwise the default.
    func resolveRoot() -> URL {
        resolveCustomRoot() ?? defaultRoot
    }

    /// Takes access to a folder the user picked and remembers it.
    func adopt(_ url: URL) throws -> URL {
        // Access first: a URL straight from the open panel has to be opened
        // before it can be bookmarked.
        beginAccess(to: url)
        try verifyUsable(url)

        // Remembering it is best effort. If the bookmark cannot be written the
        // app still works this session -- it just falls back to the default
        // folder next launch, which beats refusing the folder outright.
        try? store(url)
        return url
    }

    /// Goes back to the default folder, releasing any custom one.
    func useDefaultRoot() -> URL {
        stopAccess()
        defaults.removeObject(forKey: Self.bookmarkKey)
        return defaultRoot
    }

    // MARK: - Custom root

    private func resolveCustomRoot() -> URL? {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            _ = useDefaultRoot()
            return nil
        }

        beginAccess(to: url)
        guard (try? verifyUsable(url)) != nil else {
            // Renamed, deleted, or on an unmounted volume. Fall back to the
            // default rather than leaving the app stuck on a folder it cannot use.
            _ = useDefaultRoot()
            return nil
        }
        if isStale { try? store(url) }
        return url
    }

    private func store(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        defaults.set(bookmark, forKey: Self.bookmarkKey)
    }

    // MARK: - Access

    /// A `false` return from `startAccessingSecurityScopedResource()` is not a
    /// failure: it means the URL carries no security scope, which is the case
    /// for a folder the app can already reach. Only a scope actually taken here
    /// gets released later.
    private func beginAccess(to url: URL) {
        stopAccess()
        if url.startAccessingSecurityScopedResource() {
            accessedURL = url
        }
    }

    private func stopAccess() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    /// Confirms the folder is really there and really writable. Under a sandbox
    /// the only reliable test is to write something, so a probe file is created
    /// and removed immediately -- catching an unusable choice now rather than on
    /// the user's first save.
    private func verifyUsable(_ url: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            let probe = url.appending(path: ".requester-write-check")
            try Data().write(to: probe, options: .atomic)
            try? fileManager.removeItem(at: probe)
        } catch {
            throw StorageRootError.notUsable(
                path: url.path(percentEncoded: false), reason: error.localizedDescription
            )
        }
    }
}

nonisolated enum StorageRootError: LocalizedError {
    case notUsable(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .notUsable(let path, let reason):
            "Requester cannot write to “\(path)”. \(reason)"
        }
    }

    var recoverySuggestion: String? {
        "Pick a folder inside your home directory, or go back to the default folder."
    }
}
