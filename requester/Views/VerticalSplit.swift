import AppKit
import SwiftUI

/// A draggable vertical split with a definite height for each half.
///
/// Deliberately not `VSplitView`. That is backed by `NSSplitView`, whose divider
/// position is derived from its children's sizes -- and a child that reports
/// "whatever height you propose", as an `NSViewRepresentable` filling its space
/// does, closes the loop: size depends on divider, divider depends on size.
/// AppKit re-enters layout resolving it until the stack overflows and the
/// process dies. Measuring the split here instead means both halves are handed
/// a concrete height and nothing has to be resolved iteratively.
struct VerticalSplit<Top: View, Bottom: View>: View {
    var minTopHeight: CGFloat = 200
    var minBottomHeight: CGFloat = 160
    var initialTopFraction: CGFloat = 0.5

    @ViewBuilder var top: Top
    @ViewBuilder var bottom: Bottom

    private static var dividerThickness: CGFloat { 9 }

    @State private var fraction: CGFloat?
    @State private var fractionAtDragStart: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let available = max(proxy.size.height - Self.dividerThickness, 1)
            let topHeight = resolvedTopHeight(in: available)

            VStack(spacing: 0) {
                top
                    .frame(height: topHeight)
                divider(available: available)
                bottom
                    .frame(height: max(available - topHeight, 0))
            }
        }
    }

    /// Clamped so neither half is squeezed below its minimum, and so a window
    /// too short for both minimums still produces sane, finite heights.
    private func resolvedTopHeight(in available: CGFloat) -> CGFloat {
        let desired = available * (fraction ?? initialTopFraction)
        let highest = max(available - minBottomHeight, minTopHeight)
        return min(max(desired, min(minTopHeight, available)), max(highest, 1))
    }

    private func divider(available: CGFloat) -> some View {
        ZStack {
            Color.clear
            Divider()
        }
        .frame(height: Self.dividerThickness)
        .contentShape(.rect)
        .onHover { isInside in
            if isInside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = fractionAtDragStart ?? (fraction ?? initialTopFraction)
                    if fractionAtDragStart == nil { fractionAtDragStart = start }
                    let moved = available * start + value.translation.height
                    fraction = min(max(moved / available, 0), 1)
                }
                .onEnded { _ in fractionAtDragStart = nil }
        )
    }
}
