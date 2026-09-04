import Foundation

/// Decides where the app's data lives.
///
/// That is the standard per-app support folder, which inside the sandbox is the
/// app's own container: it needs no permission, no prompt, and nothing to
/// configure. `REQUESTER_DATA_ROOT` overrides it for scripted runs and UI tests;
/// see `LaunchState`.
nonisolated enum StorageRootStore {
    private static let folderName = "Requester"

    /// `Application Support/Requester`, resolved inside the app's container.
    static var defaultRoot: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")

        return support.appending(path: folderName, directoryHint: .isDirectory)
    }
}
