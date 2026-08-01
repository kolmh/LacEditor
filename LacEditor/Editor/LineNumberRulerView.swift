import AppKit

final class LineNumberRulerView: NSRulerView {
    var lineNumberProvider: ((Int) -> Int)?

    override var isOpaque: Bool { true }

    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let padding: CGFloat = 9
    private let topLineOverlay = LineNumberTopOverlayView()

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        addSubview(topLineOverlay)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: bounds)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.lacEditorBackground.setFill()
        bounds.fill(using: .copy)
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleRect = textView.visibleRect
        let containerRect = visibleRect.offsetBy(
            dx: -textView.textContainerOrigin.x,
            dy: -textView.textContainerOrigin.y
        )
        layoutManager.ensureLayout(
            forBoundingRect: containerRect,
            in: textContainer
        )
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: containerRect,
            in: textContainer
        )
        let nsString = textView.string as NSString
        let firstCharacterLocation: Int
        if containerRect.minY <= 0.5 || nsString.length == 0 {
            firstCharacterLocation = 0
        } else {
            let firstGlyph = layoutManager.glyphIndex(
                for: NSPoint(x: 0, y: containerRect.minY),
                in: textContainer,
                fractionOfDistanceThroughGlyph: nil
            )
            firstCharacterLocation = min(
                layoutManager.characterIndexForGlyph(at: firstGlyph),
                nsString.length
            )
        }
        let visibleCharacterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange,
            actualGlyphRange: nil
        )
        let characterRange = NSRange(
            location: firstCharacterLocation,
            length: max(
                0,
                NSMaxRange(visibleCharacterRange) - firstCharacterLocation
            )
        )

        var lineNumber = lineNumberProvider?(characterRange.location) ?? 1
        if lineNumberProvider == nil, characterRange.location > 0 {
            lineNumber = LogicalLineIndex(
                text: nsString.substring(to: characterRange.location)
            ).lineNumber(at: characterRange.location)
        }
        var index = nsString.lineRange(for: NSRange(location: characterRange.location, length: 0)).location
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        var layoutTracker = LineNumberLayoutTracker()
        var capturedTopLine = false
        topLineOverlay.isHidden = true

        while index < NSMaxRange(characterRange), index < nsString.length {
            let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
            if let foldLayoutManager = layoutManager as? FoldLayoutManager,
               foldLayoutManager.isCharacterRangeFullyFolded(lineRange) {
                lineNumber += 1
                index = NSMaxRange(lineRange)
                continue
            }
            let anchor = LogicalLineIndex.layoutAnchorCharacterIndex(
                in: nsString,
                lineRange: lineRange
            )
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: anchor)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            lineRect.origin.x += textView.textContainerOrigin.x
            lineRect.origin.y += textView.textContainerOrigin.y
            let rulerRect = convert(lineRect, from: textView)
            if !capturedTopLine,
               rulerRect.maxY >= bounds.minY,
               rulerRect.minY <= bounds.maxY {
                capturedTopLine = true
                topLineOverlay.update(
                    lineNumber: lineNumber,
                    labelY: rulerRect.minY,
                    rowHeight: max(rulerRect.height, font.pointSize + 4),
                    rulerWidth: bounds.width
                )
            }
            if rulerRect.maxY >= rect.minY,
               rulerRect.minY <= rect.maxY,
               layoutTracker.shouldDraw(at: rulerRect.minY) {
                draw(lineNumber: lineNumber, y: rulerRect.minY, attributes: attributes)
            }
            lineNumber += 1
            index = NSMaxRange(lineRange)
        }

        let trailingCharacter = nsString.length > 0
            ? nsString.character(at: nsString.length - 1)
            : 0
        let hasTrailingEmptyLine = nsString.length == 0
            || trailingCharacter == 0x0A
            || trailingCharacter == 0x0D
            || trailingCharacter == 0x2028
            || trailingCharacter == 0x2029
        if hasTrailingEmptyLine {
            let extraRect = layoutManager.extraLineFragmentRect
            var textViewRect = extraRect
            if extraRect.isEmpty {
                textViewRect = NSRect(
                    x: textView.textContainerOrigin.x,
                    y: textView.textContainerOrigin.y,
                    width: 1,
                    height: font.pointSize + 3
                )
            } else {
                textViewRect.origin.x += textView.textContainerOrigin.x
                textViewRect.origin.y += textView.textContainerOrigin.y
            }
            let rulerRect = convert(textViewRect, from: textView)
            if rulerRect.maxY >= rect.minY,
               rulerRect.minY <= rect.maxY,
               layoutTracker.shouldDraw(at: rulerRect.minY) {
                draw(lineNumber: lineNumber, y: rulerRect.minY, attributes: attributes)
            }
        }
    }

    private func draw(lineNumber: Int, y: CGFloat, attributes: [NSAttributedString.Key: Any]) {
        let value = "\(lineNumber)" as NSString
        let size = value.size(withAttributes: attributes)
        value.draw(
            at: NSPoint(x: bounds.width - padding - size.width, y: y),
            withAttributes: attributes
        )
    }

}

private final class LineNumberTopOverlayView: NSView {
    override var isOpaque: Bool { true }

    private let font = NSFont.monospacedDigitSystemFont(
        ofSize: 11,
        weight: .regular
    )
    private let padding: CGFloat = 9
    private var lineNumber = 1
    private var labelY: CGFloat = 0

    func update(
        lineNumber: Int,
        labelY: CGFloat,
        rowHeight: CGFloat,
        rulerWidth: CGFloat
    ) {
        self.lineNumber = lineNumber
        self.labelY = labelY
        frame = NSRect(
            x: 0,
            y: 0,
            width: rulerWidth,
            height: max(rowHeight, labelY + rowHeight)
        )
        isHidden = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.lacEditorBackground.setFill()
        bounds.fill(using: .copy)
        NSColor.separatorColor.setFill()
        NSRect(
            x: bounds.maxX - 1,
            y: bounds.minY,
            width: 1,
            height: bounds.height
        ).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let value = "\(lineNumber)" as NSString
        let size = value.size(withAttributes: attributes)
        value.draw(
            at: NSPoint(
                x: bounds.width - padding - size.width,
                y: labelY
            ),
            withAttributes: attributes
        )
    }
}
