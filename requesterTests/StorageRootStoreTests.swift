import Foundation
import Testing
@testable import requester

/// Locating the data folder is the very first thing the app does, so both the
/// default path and the optional custom one are pinned here.
@MainActor
struct StorageRootStoreTests {
    private func makeStore() -> (StorageRootStore, UserDefaults) {
        // An isolated defaults suite, so tests never touch the real preference.
        let suiteName = "requester-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (StorageRootStore(defaults: defaults), defaults)
    }

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func usesTheDefaultFolderWithNoSetupAtAll() {
        // Arrange
        let (store, _) = makeStore()

        // Act
        let root = store.resolveRoot()

        // Assert -- a real, writable location under Application Support, and no
        // prompt required to get it
        #expect(store.isUsingDefaultRoot)
        #expect(root == store.defaultRoot)
        #expect(root.lastPathComponent == "Requester")
        #expect(root.path(percentEncoded: false).contains("Application Support"))
    }

    @Test func theDefaultFolderCanActuallyBeOpened() throws {
        // Arrange
        let (store, _) = makeStore()
        let root = store.resolveRoot()

        // Act -- exactly what the app does at launch. Nothing is written into
        // it: this is the real data folder, not a scratch one.
        _ = try LocalFileStorage(root: root)

        // Assert
        #expect(FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
    }

    /// The regression: `startAccessingSecurityScopedResource()` returns false for
    /// a folder that needs no security scope, and that was treated as a failure --
    /// so every folder the user picked was rejected.
    @Test func acceptsAFolderThatNeedsNoSecurityScope() throws {
        // Arrange
        let (store, _) = makeStore()
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(folder.startAccessingSecurityScopedResource() == false)

        // Act
        let adopted = try store.adopt(folder)

        // Assert
        #expect(adopted == folder)
        #expect(store.isUsingDefaultRoot == false)
    }

    @Test func remembersACustomFolderForTheNextLaunch() throws {
        // Arrange
        let (store, defaults) = makeStore()
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Act
        _ = try store.adopt(folder)

        // Assert -- a fresh store over the same defaults finds it again
        let nextLaunch = StorageRootStore(defaults: defaults)
        #expect(nextLaunch.resolveRoot().standardizedFileURL == folder.standardizedFileURL)
    }

    @Test func fallsBackToTheDefaultWhenACustomFolderIsGone() throws {
        // Arrange
        let (store, defaults) = makeStore()
        let folder = try makeFolder()
        _ = try store.adopt(folder)

        // Act -- the folder is deleted between launches
        try FileManager.default.removeItem(at: folder)
        let nextLaunch = StorageRootStore(defaults: defaults)
        let root = nextLaunch.resolveRoot()

        // Assert -- the app still opens, on the default folder
        #expect(root == nextLaunch.defaultRoot)
        #expect(nextLaunch.isUsingDefaultRoot)
    }

    @Test func revertsToTheDefaultOnRequest() throws {
        // Arrange
        let (store, _) = makeStore()
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try store.adopt(folder)

        // Act
        let root = store.useDefaultRoot()

        // Assert
        #expect(root == store.defaultRoot)
        #expect(store.isUsingDefaultRoot)
    }

    @Test func rejectsAFolderItCannotWriteTo() {
        // Arrange -- outside the sandbox, so the write is denied
        let (store, _) = makeStore()
        let denied = URL(filePath: "/Library/Application Support/requester-should-fail")

        // Act / Assert
        #expect(throws: StorageRootError.self) {
            _ = try store.adopt(denied)
        }
        // The choice is not remembered, so the app keeps using the default
        #expect(store.isUsingDefaultRoot)
    }
}
