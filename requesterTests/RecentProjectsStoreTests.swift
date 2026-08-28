import Foundation
import Testing
@testable import requester

/// The launcher's list comes straight from here, so ordering and the guards
/// against listing a project that no longer exists are what matter.
@MainActor
struct RecentProjectsStoreTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "requester-tests-\(UUID().uuidString)")!
    }

    private func project(_ id: String, name: String) -> Project {
        Project(id: id, name: name)
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

    /// A remembered id is a hint: the data folder may have been swapped or
    /// edited by hand, and a row that cannot be opened is worse than no row.
    @Test func resolvesOnlyProjectsThatStillExist() {
        // Arrange
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let store = RecentProjectsStore(defaults: defaults)
        store.markOpened("gone")
        store.markOpened("kept")

        // Act
        let resolved = store.resolve(
            against: [project("kept", name: "Kept"), project("never-opened", name: "Other")]
        )

        // Assert -- recency order, and the missing one simply absent
        #expect(resolved.map(\.id) == ["kept"])
    }
}
