import AppKit

/// The gutter down the left of a code editor: the line number of every row on
/// screen, and a triangle on each row that opens a block worth collapsing.
///
/// A plain view laid out *beside* the scroll view rather than an `NSRulerView`.
/// AppKit reserves a ruler's width as a left content inset on a clip view that
/// stays full width, so the ruler is painted over the text and the text is
/// clear of it at exactly one scroll position -- the leftmost. Every other
/// position, which is any sideways scroll and any resize that re-clamps one,
/// slides the first characters of every line underneath the numbers. Two views
/// side by side cannot overlap at any offset, so none of that arithmetic
/// exists here.
///
/// It never walks the document. TextKit is asked which layout fragments cover
/// the visible rectangle -- a screenful, whatever the response weighs -- and
/// each one's offset is turned into a line number by a binary search into the
/// projection. Numbers are the *source* line, so a row after a collapsed block
/// reports the line it really is rather than its position on screen.
final class LineNumberGutter: NSView {
    /// Everything the gutter draws from, replaced wholesale when the text does.
    struct Source {
        var document: FoldableText
        var projection: FoldableText.Projection
        var folded: Set<Int>

        /// Fold triangles are only offered where collapsing means something --
        /// the raw view of a body has no blocks to speak of.
        var showsFoldControls: Bool
    }

    var source: Source? {
        didSet {
            // The width follows the highest line number, so a new document can
            // need a different one and the container has to lay out again.
            if thickness(for: source) != thickness(for: oldValue) {
                superview?.needsLayout = true
            }
            needsDisplay = true
        }
    }

    /// Called with the source line whose triangle was clicked.
    var onToggleFold: ((Int) -> Void)?

    private static let horizontalPadding: CGFloat = 6
    private static let foldControlWidth: CGFloat = 13

    private static let font = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.smallSystemFontSize, weight: .regular
    )

    /// The editor being numbered. Weak, and read through rather than copied
    /// from, so the gutter always draws against the scroll position of the
    /// moment.
    private weak var scrollView: NSScrollView?

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)

        // AppKit views do not clip to their bounds by default, and a number
        // near the edge would otherwise paint out over the text.
        clipsToBounds = true

        // Nothing redraws a sibling of the clip view when the document moves
        // under it, so the gutter follows the clip view's bounds itself.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func clipViewDidScroll() {
        needsDisplay = true
    }

    /// Numbers count downwards, like the text view they sit against.
    override var isFlipped: Bool { true }

    // MARK: - Size

    /// Wide enough for the highest line number the document can show, so the
    /// text does not shift sideways as the reader scrolls into five digits.
    ///
    /// Zero without a source: a gutter with nothing to number takes no width,
    /// which is how the raw view of a response gives it all back to the text.
    var thickness: CGFloat { thickness(for: source) }

    private func thickness(for source: Source?) -> CGFloat {
        guard let source else { return 0 }
        let digits = max(String(source.document.lineCount).count, 2)
        let width = ("0" as NSString)
            .size(withAttributes: [.font: Self.font]).width * CGFloat(digits)
        let controls = source.showsFoldControls ? Self.foldControlWidth : 0
        return (width + controls + Self.horizontalPadding * 2).rounded(.up)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        let edge = NSBezierPath()
        edge.move(to: CGPoint(x: bounds.maxX - 0.5, y: dirtyRect.minY))
        edge.line(to: CGPoint(x: bounds.maxX - 0.5, y: dirtyRect.maxY))
        edge.lineWidth = 1
        edge.stroke()

        enumerateVisibleRows { sourceLine, isFoldable, rowRect in
            self.draw(number: sourceLine + 1, in: rowRect)
            if isFoldable {
                self.drawFoldControl(
                    collapsed: self.source?.folded.contains(sourceLine) ?? false, in: rowRect
                )
            }
        }
    }

    private func draw(number: Int, in rowRect: NSRect) {
        let label = String(number) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font, .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: CGPoint(
                x: bounds.maxX - Self.horizontalPadding - size.width,
                y: rowRect.minY + (rowRect.height - size.height) / 2
            ),
            withAttributes: attributes
        )
    }

    /// A disclosure triangle, pointing down when the block is open and right
    /// when it is collapsed -- the direction the reader already knows from
    /// every outline view on the system.
    private func drawFoldControl(collapsed: Bool, in rowRect: NSRect) {
        let box = NSRect(
            x: Self.horizontalPadding - 2,
            y: rowRect.minY + (rowRect.height - Self.foldControlWidth) / 2,
            width: Self.foldControlWidth,
            height: Self.foldControlWidth
        ).insetBy(dx: 3, dy: 3)

        let triangle = NSBezierPath()
        if collapsed {
            // Pointing right, which reads the same either way up.
            triangle.move(to: CGPoint(x: box.minX, y: box.minY))
            triangle.line(to: CGPoint(x: box.maxX, y: box.midY))
            triangle.line(to: CGPoint(x: box.minX, y: box.maxY))
        } else {
            // Pointing down. The gutter is flipped like the text view, so
            // "down" is the larger y.
            triangle.move(to: CGPoint(x: box.minX, y: box.minY))
            triangle.line(to: CGPoint(x: box.maxX, y: box.minY))
            triangle.line(to: CGPoint(x: box.midX, y: box.maxY))
        }
        triangle.close()
        NSColor.tertiaryLabelColor.setFill()
        triangle.fill()
    }

    // MARK: - Scrolling

    /// A wheel or trackpad gesture over the numbers scrolls the text, as it
    /// did while the gutter was inside the scroll view. Nothing routes it there
    /// now that the two are siblings -- the responder chain goes up to the
    /// container, not across -- so it is handed over by hand.
    override func scrollWheel(with event: NSEvent) {
        guard let scrollView else { return super.scrollWheel(with: event) }
        scrollView.scrollWheel(with: event)
    }

    // MARK: - Folding

    override func mouseDown(with event: NSEvent) {
        guard source?.showsFoldControls == true else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        guard point.x < Self.horizontalPadding + Self.foldControlWidth else {
            return super.mouseDown(with: event)
        }

        var toggled: Int?
        enumerateVisibleRows { sourceLine, isFoldable, rowRect in
            if isFoldable, rowRect.contains(CGPoint(x: rowRect.midX, y: point.y)) {
                toggled = sourceLine
            }
        }
        guard let toggled else { return super.mouseDown(with: event) }
        onToggleFold?(toggled)
    }

    // MARK: - Visible rows

    /// Each row on screen, as the source line it shows, whether that line opens
    /// a collapsible block, and where it sits in the gutter's own coordinates.
    private func enumerateVisibleRows(
        _ body: (_ sourceLine: Int, _ isFoldable: Bool, _ rowRect: NSRect) -> Void
    ) {
        guard let scrollView,
              let textView = scrollView.documentView as? NSTextView,
              let layoutManager = textView.textLayoutManager,
              let contentStorage = textView.textContentStorage,
              let source
        else { return }

        // Fragment frames are in the text container's space; the text view
        // insets them, and the gutter sits in a third space of its own -- one
        // the scrolling never moves, which is what the conversion crosses.
        let visible = scrollView.contentView.bounds
        let inset = textView.textContainerInset.height
        let gutterOrigin = convert(NSPoint.zero, from: textView).y
        let top = visible.minY - inset

        guard let first = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(top, 0)))
        else { return }

        layoutManager.enumerateTextLayoutFragments(
            from: first.rangeInElement.location, options: [.ensuresLayout]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard frame.minY <= top + visible.height else { return false }

            let offset = contentStorage.offset(
                from: contentStorage.documentRange.location, to: fragment.rangeInElement.location
            )
            let displayed = source.projection.displayedLine(containing: offset)
            guard displayed < source.projection.sourceLines.count else { return false }
            let sourceLine = source.projection.sourceLines[displayed]

            let isFoldable = source.showsFoldControls
                && source.document.closingLine(for: sourceLine) != nil

            body(
                sourceLine,
                isFoldable,
                NSRect(
                    x: 0,
                    y: frame.minY + inset + gutterOrigin,
                    width: self.bounds.width,
                    // A wrapped paragraph is one tall fragment: the number
                    // belongs on its first row, not centred over all of them.
                    height: min(frame.height, textView.font?.boundingRectForFont.height ?? 16)
                )
            )
            return true
        }
    }
}
