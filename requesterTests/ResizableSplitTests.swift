import Foundation
import Testing
@testable import requester

/// Where the divider of a `ResizableSplit` is allowed to sit.
///
/// The bug this guards: the split stored whatever fraction a drag computed,
/// including positions the pane minimums then overruled on screen. The stored
/// value and the visible divider drifted apart, so the next drag started from a
/// position the divider was not at -- it sat still through the gap and then
/// jumped to catch up. Every position a drag can produce is clamped here
/// instead, which is pure arithmetic and needs no window.
struct ResizableSplitTests {
    private let geometry = SplitGeometry(
        available: 1000, minimumFirst: 400, minimumSecond: 200
    )

    @Test func splitsAtTheRequestedFractionWhenBothPanesFit() {
        // Arrange / Act
        let size = geometry.firstSize(fraction: 0.6)

        // Assert
        #expect(size == 600)
    }

    @Test func keepsTheFirstPaneAtItsMinimum() {
        // Act
        let size = geometry.firstSize(fraction: 0.1)

        // Assert
        #expect(size == 400)
    }

    @Test func keepsTheSecondPaneAtItsMinimum() {
        // Act
        let size = geometry.firstSize(fraction: 0.95)

        // Assert -- 1000 - 200, so the second pane still gets its 200
        #expect(size == 800)
    }

    /// The heart of the fix: a drag past the end stores the position the
    /// divider is really at, so resuming from it moves the divider at once.
    @Test func storesOnlyPositionsTheDividerCanReach() {
        // Act -- dragged far past where the second pane's minimum stops it
        let stored = geometry.fraction(forFirstSize: 2000)

        // Assert
        #expect(stored == 0.8)
        #expect(geometry.firstSize(fraction: stored) == 800)
    }

    @Test func resumesADragFromTheVisiblePosition() {
        // Arrange -- a fraction the minimums overrule, as an older build or a
        // window resize could leave behind
        let start = geometry.reachableFraction(0.05)

        // Act -- nudge the divider 50pt right of where it actually sits
        let moved = geometry.fraction(forFirstSize: geometry.available * start + 50)

        // Assert -- it moves the full 50, rather than spending it on the gap
        #expect(geometry.firstSize(fraction: start) == 400)
        #expect(geometry.firstSize(fraction: moved) == 450)
    }

    @Test func leavesAReachableFractionAlone() {
        // Act / Assert
        #expect(geometry.reachableFraction(0.6) == 0.6)
    }

    /// Both minimums cannot be met, so they are advisory rather than a licence
    /// to overflow: the panes still have to fit inside the window.
    @Test func fitsInsideAContainerTooSmallForBothMinimums() {
        // Arrange
        let cramped = SplitGeometry(available: 500, minimumFirst: 400, minimumSecond: 200)

        // Act
        let widest = cramped.firstSize(fraction: 1)
        let narrowest = cramped.firstSize(fraction: 0)

        // Assert
        #expect(widest <= cramped.available)
        #expect(narrowest >= 0)
        #expect(narrowest <= widest)
    }

    @Test func givesFiniteSizesForAContainerWithNoRoomAtAll() {
        // Arrange -- a window narrower than the divider itself
        let empty = SplitGeometry(available: -5, minimumFirst: 400, minimumSecond: 200)

        // Act
        let size = empty.firstSize(fraction: 0.5)

        // Assert
        #expect(empty.available == 1)
        #expect(size.isFinite)
        #expect(size <= 1)
    }
}
