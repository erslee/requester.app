import AppKit

/// The gutter down the left of a code editor: the line number of every row on
/// screen, and a triangle on each row that opens a block worth collapsing.
///
/// It never walks the document. TextKit is asked which layout fragments cover
/// the visible rectangle -- a screenful, whatever the response weighs -- and
/// each one's offset is turned into a line number by a binary search into the
/// projection. Numbers are the *source* line, so a row after a collapsed block
/// reports the line it really is rather than its position on screen.
final class LineNumberRuler: NSRulerView {
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
            invalidateThickness()
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

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = scrollView.documentView

        // AppKit views do not clip to their bounds by default, and a ruler's
        // frame follows the document -- without this the gutter paints over the
        // whole window.
        clipsToBounds = true

        // Rulers are not redrawn by scrolling on their own, so the gutter
        // follows the clip view's bounds instead.
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

    // MARK: - Size

    /// Wide enough for the highest line number the document can show, so the
    /// text does not shift sideways as the reader scrolls into five digits.
    ///
    /// The scroll view is re-tiled whenever that width changes. It insets its
    /// content view by the thickness it last tiled at, not by the current one,
    /// so a gutter that grew past it -- which is every gutter, since AppKit
    /// starts at 16pt and two digits already need more -- would paint over the
    /// first characters of every line.
    private func invalidateThickness() {
        let digits = max(String(source?.document.lineCount ?? 1).count, 2)
        let width = ("0" as NSString)
            .size(withAttributes: [.font: Self.font]).width * CGFloat(digits)
        let controls = (source?.showsFoldControls ?? false) ? Self.foldControlWidth : 0
        let thickness = (width + controls + Self.horizontalPadding * 2).rounded(.up)

        guard abs(thickness - ruleThickness) > 0.5 else { return }
        ruleThickness = thickness
        // Tiling lays out the document, so it is only worth doing on a real
        // change -- and the guard above is what keeps this off the path of
        // every scroll and every redraw.
        scrollView?.tile()
        returnToStartOfLine()
    }

    /// Puts the document back against the start of its lines after a re-tile.
    ///
    /// Room for the gutter is reserved as a *left content inset* on the clip
    /// view, not by narrowing it -- so the leftmost scroll position is minus
    /// that inset, and `x = 0` is the position where the gutter covers the
    /// first characters of every line. A document nobody has scrolled sits at
    /// 0 until something moves it, which is why the text arrived clipped and
    /// a short line -- the `[` opening a JSON array -- vanished entirely.
    ///
    /// Only the horizontal offset is touched: the row the reader is on is
    /// worth keeping, the column they never chose is not.
    ///
    /// Not private: a gutter switched off and back on again -- Raw, then
    /// Pretty -- re-takes its inset without ever changing thickness, so the
    /// install path has to ask for this rather than reaching it through a
    /// re-tile.
    func returnToStartOfLine() {
        guard let clipView = scrollView?.contentView else { return }
        let start = -clipView.contentInsets.left
        guard abs(clipView.bounds.origin.x - start) > 0.5 else { return }
        clipView.scroll(to: NSPoint(x: start, y: clipView.bounds.origin.y))
        scrollView?.reflectScrolledClipView(clipView)
    }

    // MARK: - Drawing

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        let edge = NSBezierPath()
        edge.move(to: CGPoint(x: bounds.maxX - 0.5, y: rect.minY))
        edge.line(to: CGPoint(x: bounds.maxX - 0.5, y: rect.maxY))
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
            // Pointing down. The ruler inherits the text view's flipped
            // coordinates, so "down" is the larger y.
            triangle.move(to: CGPoint(x: box.minX, y: box.minY))
            triangle.line(to: CGPoint(x: box.maxX, y: box.minY))
            triangle.line(to: CGPoint(x: box.midX, y: box.maxY))
        }
        triangle.close()
        NSColor.tertiaryLabelColor.setFill()
        triangle.fill()
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
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.textLayoutManager,
              let contentStorage = textView.textContentStorage,
              let source,
              let visible = scrollView?.contentView.bounds
        else { return }

        // Fragment frames are in the text container's space; the text view
        // insets them, and the ruler sits in a third space of its own.
        let inset = textView.textContainerInset.height
        let rulerOrigin = convert(NSPoint.zero, from: textView).y
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
                    y: frame.minY + inset + rulerOrigin,
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
