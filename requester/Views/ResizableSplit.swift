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

    var body: some View {
        GeometryReader { proxy in
            let total = axis == .horizontal ? proxy.size.width : proxy.size.height
            let available = max(total - Self.dividerThickness, 1)
            let firstSize = resolvedFirstSize(in: available)
            let secondSize = max(available - firstSize, 0)

            switch axis {
            case .horizontal:
                HStack(spacing: 0) {
                    first.frame(width: firstSize)
                    divider(available: available)
                    second.frame(width: secondSize)
                }
            case .vertical:
                VStack(spacing: 0) {
                    first.frame(height: firstSize)
                    divider(available: available)
                    second.frame(height: secondSize)
                }
            }
        }
    }

    /// Clamped so neither pane drops below its minimum, and so a window too
    /// small for both minimums still yields finite, ordered sizes.
    private func resolvedFirstSize(in available: CGFloat) -> CGFloat {
        let desired = available * (fraction ?? initialFraction)
        let highest = max(available - minimumSecond, minimumFirst)
        return min(max(desired, min(minimumFirst, available)), max(highest, 1))
    }

    private func divider(available: CGFloat) -> some View {
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
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = fractionAtDragStart ?? (fraction ?? initialFraction)
                    if fractionAtDragStart == nil { fractionAtDragStart = start }
                    let moved = available * start
                        + (axis == .horizontal ? value.translation.width : value.translation.height)
                    fraction = min(max(moved / available, 0), 1)
                }
                .onEnded { _ in fractionAtDragStart = nil }
        )
    }
}
