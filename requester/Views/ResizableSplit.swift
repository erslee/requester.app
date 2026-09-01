import AppKit
import SwiftUI

/// A draggable two-pane split that gives each pane a definite size.
///
/// Deliberately not `HSplitView`, `VSplitView`, or `.inspector`. Those are
/// `NSSplitView`-backed, and two of its behaviours cause trouble here:
///
/// - It autosaves *absolute* pane sizes. A width saved while the window was
///   narrow is restored verbatim into a wide window, leaving a pane a sliver of
///   its stated minimum, and resizing the window does not redistribute it.
/// - The autosave key is derived from the SwiftUI view's mangled type name, so
///   adding any modifier anywhere in the chain silently resets the layout.
///
/// A stored *fraction* has neither problem: it scales with the window, and the
/// minimums are enforced here on every layout rather than being advisory. Each
/// pane is also handed a concrete size, which keeps `NSViewRepresentable`
/// children -- the code editors -- from negotiating a size with the split and
/// sending AppKit into a layout loop.
struct ResizableSplit<First: View, Second: View>: View {
    var axis: Axis = .horizontal
    var minimumFirst: CGFloat
    var minimumSecond: CGFloat
    var initialFraction: CGFloat = 0.5

    @ViewBuilder var first: First
    @ViewBuilder var second: Second

    private static var dividerThickness: CGFloat { 9 }

    @State private var fraction: CGFloat?
    @State private var fractionAtDragStart: CGFloat?

    /// The drag is measured against the split's own container rather than the
    /// divider it is attached to. A `.local` space moves with the divider, so
    /// each event was measured from an origin the previous event had already
    /// shifted -- the translation collapsed back to zero and the divider
    /// juddered between two positions for as long as the mouse kept moving.
    /// The name is per-instance so nesting one split inside another cannot make
    /// the inner gesture resolve against the outer container.
    @Namespace private var container

    var body: some View {
        GeometryReader { proxy in
            let total = axis == .horizontal ? proxy.size.width : proxy.size.height
            let geometry = SplitGeometry(
                available: total - Self.dividerThickness,
                minimumFirst: minimumFirst,
                minimumSecond: minimumSecond
            )
            let firstSize = geometry.firstSize(fraction: fraction ?? initialFraction)
            let secondSize = max(geometry.available - firstSize, 0)

            switch axis {
            case .horizontal:
                HStack(spacing: 0) {
                    first.frame(width: firstSize)
                    divider(in: geometry)
                    second.frame(width: secondSize)
                }
            case .vertical:
                VStack(spacing: 0) {
                    first.frame(height: firstSize)
                    divider(in: geometry)
                    second.frame(height: secondSize)
                }
            }
        }
        .coordinateSpace(.named(container))
    }

    private func divider(in geometry: SplitGeometry) -> some View {
        ZStack {
            Color.clear
            Divider()
        }
        .frame(
            width: axis == .horizontal ? Self.dividerThickness : nil,
            height: axis == .vertical ? Self.dividerThickness : nil
        )
        .contentShape(.rect)
        .onHover { isInside in
            let cursor: NSCursor = axis == .horizontal ? .resizeLeftRight : .resizeUpDown
            if isInside { cursor.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(container))
                .onChanged { value in
                    // A drag resumes from where the divider actually is. The
                    // stored fraction can name a position the minimums
                    // overruled, and starting there would spend the first part
                    // of the drag closing that gap instead of moving.
                    let start = fractionAtDragStart
                        ?? geometry.reachableFraction(fraction ?? initialFraction)
                    fractionAtDragStart = start
                    let moved = geometry.available * start
                        + (axis == .horizontal ? value.translation.width : value.translation.height)
                    fraction = geometry.fraction(forFirstSize: moved)
                }
                .onEnded { _ in fractionAtDragStart = nil }
        )
    }
}

/// Where the divider may sit, for a split of a given size.
///
/// Split out from the view because it is the whole of the layout's behaviour
/// and none of it needs a window: every position is clamped to the range the
/// two minimums leave reachable, so what is stored and what is on screen can
/// never disagree.
nonisolated struct SplitGeometry: Equatable {
    /// The space the two panes share, the divider already taken out of it.
    let available: CGFloat
    let minimumFirst: CGFloat
    let minimumSecond: CGFloat

    init(available: CGFloat, minimumFirst: CGFloat, minimumSecond: CGFloat) {
        // A container too small for the divider alone would otherwise divide
        // by zero and hand the panes a NaN width.
        self.available = max(available, 1)
        self.minimumFirst = minimumFirst
        self.minimumSecond = minimumSecond
    }

    /// The size of the first pane for a stored fraction.
    func firstSize(fraction: CGFloat) -> CGFloat {
        clamped(available * fraction)
    }

    /// The fraction to store for a divider dragged to `size`.
    func fraction(forFirstSize size: CGFloat) -> CGFloat {
        clamped(size) / available
    }

    /// `fraction` moved to the nearest position the minimums actually allow.
    func reachableFraction(_ fraction: CGFloat) -> CGFloat {
        self.fraction(forFirstSize: available * fraction)
    }

    /// Ordered by construction, so a container too small for both minimums
    /// still yields sizes that fit inside it -- the first pane taking what
    /// there is rather than overflowing to satisfy its minimum.
    private var smallestFirst: CGFloat { min(minimumFirst, available) }
    private var largestFirst: CGFloat { max(available - minimumSecond, smallestFirst) }

    private func clamped(_ size: CGFloat) -> CGFloat {
        min(max(size, smallestFirst), largestFirst)
    }
}
