import AppKit
import SwiftUI

/// Grows the hosting window to at least this size.
///
/// The content's own `minWidth`/`minHeight` already become the window's
/// `minSize`, so dragging an edge stops in the right place without any help.
/// The gap is a *restored* frame: a window remembered from a previous launch,
/// or from a build with a smaller minimum, comes back at its old size and
/// `minSize` does not retroactively correct it. The window then sits narrower
/// than its own content, and a split view that cannot compress that far lays
/// itself out past both edges -- the sidebar and inspector end up clipped
/// outside the window.
///
/// Not `.windowResizability(.contentMinSize)`: that derives the window's limit
/// from the content's *measured* minimum, while here the content's minimum
/// depends on the window's width, since the columns are sized from the space
/// available. The cycle makes SwiftUI invalidate constraints from inside
/// AppKit's layout pass, AppKit's feedback-loop detector fires, and the process
/// dies on launch with an uncaught exception.
struct WindowMinimumSize: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = WindowObservingView()
        view.isHidden = true
        view.onWindowChange = { [width, height] window in
            Self.apply(width: width, height: height, to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Also covers the case where the view already had its window before
        // this ran; `apply` is idempotent.
        if let window = nsView.window {
            Self.apply(width: width, height: height, to: window)
        }
    }

    /// Never reports a size of its own -- it exists only to reach the window.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSView, context: Context
    ) -> CGSize? {
        .zero
    }

    private static func apply(width: CGFloat, height: CGFloat, to window: NSWindow) {
        let size = NSSize(width: width, height: height)
        guard window.minSize != size else { return }
        window.minSize = size

        // A frame restored from an earlier build can already be below the new
        // floor, and `minSize` does not retroactively correct one. Deferred, so
        // the window is not resized from inside a layout pass.
        guard window.frame.width < width || window.frame.height < height else { return }
        DispatchQueue.main.async {
            var frame = window.frame
            frame.size.width = max(frame.width, width)
            frame.size.height = max(frame.height, height)
            window.setFrame(frame, display: true, animate: false)
        }
    }

    /// `updateNSView` can run before the view has been added to a window, and is
    /// not called again merely because one arrives -- so the view reports it.
    private final class WindowObservingView: NSView {
        var onWindowChange: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindowChange?(window) }
        }
    }
}
