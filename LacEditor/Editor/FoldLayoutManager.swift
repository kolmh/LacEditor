import AppKit

final class FoldLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    private(set) var foldedRange: NSRange?

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    func setFoldedRange(_ range: NSRange?) {
        let safeRange = range.flatMap(clampedRange)
        guard foldedRange != safeRange else { return }
        let previousRange = foldedRange
        foldedRange = safeRange

        if let previousRange {
            invalidateFoldGlyphs(in: previousRange)
        }
        if let safeRange {
            invalidateFoldGlyphs(in: safeRange)
        }
    }

    func isCharacterFolded(_ characterIndex: Int) -> Bool {
        guard let foldedRange else { return false }
        return NSLocationInRange(characterIndex, foldedRange)
    }

    func isCharacterRangeFullyFolded(_ characterRange: NSRange) -> Bool {
        guard let foldedRange, characterRange.length > 0 else { return false }
        return NSIntersectionRange(foldedRange, characterRange).length
            == characterRange.length
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard let foldedRange else { return 0 }

        var adjustedProperties = Array(
            UnsafeBufferPointer(start: properties, count: glyphRange.length)
        )
        var didFoldGlyph = false
        for offset in adjustedProperties.indices
        where NSLocationInRange(characterIndexes[offset], foldedRange) {
            adjustedProperties[offset] = .null
            didFoldGlyph = true
        }
        guard didFoldGlyph else { return 0 }

        adjustedProperties.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            layoutManager.setGlyphs(
                glyphs,
                properties: baseAddress,
                characterIndexes: characterIndexes,
                font: font,
                forGlyphRange: glyphRange
            )
        }
        return glyphRange.length
    }

    private func clampedRange(_ range: NSRange) -> NSRange? {
        let textLength = textStorage?.length ?? NSMaxRange(range)
        let safeRange = NSIntersectionRange(
            range,
            NSRange(location: 0, length: textLength)
        )
        return safeRange.length > 0 ? safeRange : nil
    }

    private func invalidateFoldGlyphs(in range: NSRange) {
        guard let safeRange = clampedRange(range) else { return }
        invalidateGlyphs(
            forCharacterRange: safeRange,
            changeInLength: 0,
            actualCharacterRange: nil
        )
    }
}
