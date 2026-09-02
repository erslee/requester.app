import Foundation
import Testing
@testable import requester

/// One list, recents first. The cases that matter are the ones where the two
/// halves meet: a remembered project that no longer exists, a folder where
/// nothing has been opened, and what the filter does to the order.
struct ProjectListingTests {
    private func project(_ id: String, _ name: String) -> Project {
        Project(id: id, name: name)
    }

    private var all: [Project] {
        [
            project("p1", "Zebra"),
            project("p2", "Alpha"),
            project("p3", "Mango"),
            project("p4", "beta"),
        ]
    }

    @Test func putsRecentlyOpenedFirstThenTheRestAlphabetically() {
        // Act
        let ordered = ProjectListing.ordered(all, recentIDs: ["p3", "p1"])

        // Assert -- the two recents in recency order, then A-Z for the others
        #expect(ordered.map(\.name) == ["Mango", "Zebra", "Alpha", "beta"])
    }

    /// Sorting is case-insensitive and locale-aware, so "beta" files with the
    /// Bs rather than after every capital letter.
    @Test func sortsTheRestCaseInsensitively() {
        // Act
        let ordered = ProjectListing.ordered(all, recentIDs: [])

        // Assert
        #expect(ordered.map(\.name) == ["Alpha", "beta", "Mango", "Zebra"])
    }

    /// A data folder can be swapped or edited by hand, so a remembered id is a
    /// hint. One that no longer resolves must not leave a gap or a dead row.
    @Test func ignoresRememberedProjectsThatAreGone() {
        // Act
        let ordered = ProjectListing.ordered(all, recentIDs: ["gone", "p2", "also-gone"])

        // Assert -- only "Alpha" was remembered and still exists; the rest sort
        #expect(ordered.map(\.name) == ["Alpha", "beta", "Mango", "Zebra"])
    }

    @Test func listsEveryProjectExactlyOnce() {
        // Act
        let ordered = ProjectListing.ordered(all, recentIDs: ["p1", "p2", "p3", "p4"])

        // Assert -- a project in the recents must not also appear in the tail
        #expect(ordered.count == all.count)
        #expect(Set(ordered.map(\.id)).count == all.count)
    }

    // MARK: - Filtering

    @Test func narrowsToNameMatchesWithoutReorderingThem() {
        // Act -- "a" is in every one of these names
        let ordered = ProjectListing.ordered(all, recentIDs: ["p3"], matching: "a")

        // Assert -- the filter narrows, it does not re-rank
        #expect(ordered.map(\.name) == ["Mango", "Alpha", "beta", "Zebra"])
    }

    @Test func matchesRegardlessOfCase() {
        // Act
        let ordered = ProjectListing.ordered(all, recentIDs: [], matching: "ZEB")

        // Assert
        #expect(ordered.map(\.name) == ["Zebra"])
    }

    @Test func matchesPartwayThroughAName() {
        // Act
        let ordered = ProjectListing.ordered(all, recentIDs: [], matching: "ang")

        // Assert
        #expect(ordered.map(\.name) == ["Mango"])
    }

    /// A field holding only spaces is an empty field as far as the user is
    /// concerned, and must not hide everything.
    @Test func treatsABlankQueryAsNoFilter() {
        // Act / Assert
        #expect(ProjectListing.ordered(all, recentIDs: [], matching: "   ").count == 4)
        #expect(ProjectListing.ordered(all, recentIDs: [], matching: "").count == 4)
    }

    @Test func returnsNothingWhenNoNameMatches() {
        // Act / Assert
        #expect(ProjectListing.ordered(all, recentIDs: ["p1"], matching: "nope").isEmpty)
    }

    @Test func handlesAnEmptyFolder() {
        // Act / Assert -- remembered ids from a previous folder resolve to nothing
        #expect(ProjectListing.ordered([], recentIDs: ["p1"], matching: "").isEmpty)
    }
}
