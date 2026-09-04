import Foundation
import Testing
@testable import requester

/// Locating the data folder is the very first thing the app does, so the path
/// it lands on is pinned here.
struct StorageRootStoreTests {
    @Test func usesTheDefaultFolderWithNoSetupAtAll() {
        // Act
        let root = StorageRootStore.defaultRoot

        // Assert -- a real location under Application Support, and no prompt
        // required to get it
        #expect(root.lastPathComponent == "Requester")
        #expect(root.path(percentEncoded: false).contains("Application Support"))
    }

    @Test func theDefaultFolderCanActuallyBeOpened() throws {
        // Arrange
        let root = StorageRootStore.defaultRoot

        // Act -- exactly what the app does at launch. Nothing is written into
        // it: this is the real data folder, not a scratch one.
        _ = try LocalFileStorage(root: root)

        // Assert
        #expect(FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
    }
}
