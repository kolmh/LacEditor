import AppKit

final class LineNumberRulerView: NSRulerView {
    var lineNumberProvider: ((Int) -> Int)?

    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let padding: CGFloat = 9

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.lacEditorBackground.setFill()
        bounds.fill()
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
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let nsString = textView.string as NSString

        var lineNumber = lineNumberProvider?(characterRange.location) ?? 1
        if lineNumberProvider == nil, characterRange.location > 0 {
            let prefix = nsString.substring(to: characterRange.location)
            lineNumber = prefix.reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            }
        }

        var index = nsString.lineRange(for: NSRange(location: characterRange.location, length: 0)).location
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        while index < NSMaxRange(characterRange), index < nsString.length {
            let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            lineRect.origin.x += textView.textContainerOrigin.x
            lineRect.origin.y += textView.textContainerOrigin.y
            let rulerRect = convert(lineRect, from: textView)
            if rulerRect.maxY >= rect.minY, rulerRect.minY <= rect.maxY {
                draw(lineNumber: lineNumber, y: rulerRect.minY, attributes: attributes)
            }
            lineNumber += 1
            index = NSMaxRange(lineRange)
        }

        let hasTrailingEmptyLine = nsString.length == 0 || nsString.hasSuffix("\n")
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
            if rulerRect.maxY >= rect.minY, rulerRect.minY <= rect.maxY {
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
