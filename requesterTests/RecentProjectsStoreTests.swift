import Foundation
import Testing
@testable import requester

/// This remembers ids and their order, nothing more -- turning them into the
/// launcher's list is `ProjectListing`'s job, and is tested there. So what
/// matters here is recency order, the cap, and that it survives a restart.
@MainActor
struct RecentProjectsStoreTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "requester-tests-\(UUID().uuidString)")!
    }

    @Test func ordersMostRecentlyOpenedFirst() {
        // Arrange
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let store = RecentProjectsStore(defaults: defaults)

        // Act
        store.markOpened("a")
        store.markOpened("b")
        store.markOpened("c")

        // Assert
        #expect(store.projectIDs == ["c", "b", "a"])
    }

    /// Re-opening a project has to move it, not add a second copy of it.
    @Test func reopeningMovesToTheFrontWithoutDuplicating() {
        // Arrange
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let store = RecentProjectsStore(defaults: defaults)
        store.markOpened("a")
        store.markOpened("b")

        // Act
        store.markOpened("a")

        // Assert
        #expect(store.projectIDs == ["a", "b"])
    }

    @Test func keepsOnlyTheMostRecentFew() {
        // Arrange
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let store = RecentProjectsStore(defaults: defaults)

        // Act -- one more than fits
        for index in 0...RecentProjectsStore.limit {
            store.markOpened("p\(index)")
        }

        // Assert -- the oldest fell off the end
        #expect(store.projectIDs.count == RecentProjectsStore.limit)
        #expect(store.projectIDs.first == "p\(RecentProjectsStore.limit)")
        #expect(!store.projectIDs.contains("p0"))
    }

    @Test func forgetsAProjectAndClearsTheKeyWhenEmptied() {
        // Arrange
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let store = RecentProjectsStore(defaults: defaults)
        store.markOpened("a")
        store.markOpened("b")

        // Act
        store.forget("a")

        // Assert
        #expect(store.projectIDs == ["b"])

        // Act -- emptying it entirely
        store.forget("b")

        // Assert -- a fresh store over the same defaults sees nothing
        #expect(RecentProjectsStore(defaults: defaults).projectIDs.isEmpty)
    }
}
