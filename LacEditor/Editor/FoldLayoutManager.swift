import AppKit

enum EditorLayoutPolicy {
    static let viewportLayoutThreshold = 500_000

    static func usesViewportLayout(textLength: Int) -> Bool {
        textLength > viewportLayoutThreshold
    }

    static func configure(
        _ layoutManager: NSLayoutManager,
        textLength: Int
    ) {
        // TextKit 1 otherwise lays out continuously from the beginning of the
        // document. That makes deep scrolling and width changes progressively
        // more expensive even for files below the large-file threshold.
        layoutManager.allowsNonContiguousLayout = true
        layoutManager.backgroundLayoutEnabled = !usesViewportLayout(
            textLength: textLength
        )
    }
}

final class FoldLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    static let defaultLineSpacing: CGFloat = 4

    /// The font selected by the user, not the fallback font AppKit may return
    /// for the first glyph in the document. Keeping these metrics independent
    /// of document contents prevents mixed CJK/Latin input from moving a line.
    var textFont = NSFont(name: "Menlo-Regular", size: 14)
        ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) {
        didSet {
            guard textFont != oldValue else { return }
            updateFontMetrics()
            invalidateEditorLayout()
        }
    }

    var editorLineSpacing = FoldLayoutManager.defaultLineSpacing {
        didSet {
            guard editorLineSpacing != oldValue else { return }
            invalidateEditorLayout()
        }
    }

    private var cachedDefaultLineHeight: CGFloat = 1
    private var cachedDefaultBaselineOffset: CGFloat = 0
    private var groupsTemporaryAttributeUpdates = false
    private var pendingTemporaryDisplayRange: NSRange?

    var editorLineHeight: CGFloat {
        max(1, cachedDefaultLineHeight + editorLineSpacing)
    }

    private(set) var foldedRange: NSRange?

    override init() {
        super.init()
        delegate = self
        updateFontMetrics()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
        updateFontMetrics()
    }

    override func setExtraLineFragmentRect(
        _ fragmentRect: NSRect,
        usedRect: NSRect,
        textContainer container: NSTextContainer
    ) {
        var fragmentRect = fragmentRect
        var usedRect = usedRect
        fragmentRect.size.height = editorLineHeight
        usedRect.size.height = editorLineHeight
        super.setExtraLineFragmentRect(
            fragmentRect,
            usedRect: usedRect,
            textContainer: container
        )
    }

    override func invalidateDisplay(forCharacterRange charRange: NSRange) {
        guard groupsTemporaryAttributeUpdates else {
            super.invalidateDisplay(forCharacterRange: charRange)
            return
        }
        if let pendingTemporaryDisplayRange {
            let start = min(pendingTemporaryDisplayRange.location, charRange.location)
            let end = max(
                NSMaxRange(pendingTemporaryDisplayRange),
                NSMaxRange(charRange)
            )
            self.pendingTemporaryDisplayRange = NSRange(
                location: start,
                length: end - start
            )
        } else {
            pendingTemporaryDisplayRange = charRange
        }
    }

    /// Groups temporary syntax color changes into one display invalidation so
    /// the screen never presents an intermediate, partially recolored frame.
    func updateTemporaryAttributes(
        in range: NSRange,
        _ updates: () -> Void
    ) {
        let wasGrouping = groupsTemporaryAttributeUpdates
        groupsTemporaryAttributeUpdates = true
        updates()
        groupsTemporaryAttributeUpdates = wasGrouping
        guard !wasGrouping else { return }
        let invalidatedRange = pendingTemporaryDisplayRange ?? range
        pendingTemporaryDisplayRange = nil
        super.invalidateDisplay(forCharacterRange: invalidatedRange)
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

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        lineSpacingAfterGlyphAt glyphIndex: Int,
        withProposedLineFragmentRect rect: NSRect
    ) -> CGFloat {
        // Line spacing is encoded in each paragraph's fixed line height by
        // LacTextView. Applying it here only affects glyph-backed lines and
        // makes TextKit's trailing extra line fragment jump when typed into.
        0
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        lineFragmentRect.pointee.size.height = editorLineHeight
        lineFragmentUsedRect.pointee.size.height = editorLineHeight
        baselineOffset.pointee = editorBaselineOffset(
            orientation: textContainer.layoutOrientation
        )
        return true
    }

    private func editorBaselineOffset(
        orientation: NSLayoutManager.TextLayoutOrientation
    ) -> CGFloat {
        switch orientation {
        case .vertical:
            return editorLineHeight / 2
        case .horizontal:
            // AppKit's default baseline includes the font's top leading. Drop
            // that visual cap-height difference before centering the glyphs.
            let topLeading = textFont.ascender - textFont.capHeight
            return (
                editorLineHeight
                    + cachedDefaultBaselineOffset
                    - topLeading
            ) / 2
        @unknown default:
            return editorLineHeight / 2
        }
    }

    private func updateFontMetrics() {
        cachedDefaultLineHeight = defaultLineHeight(for: textFont)
        cachedDefaultBaselineOffset = defaultBaselineOffset(for: textFont)
    }

    private func invalidateEditorLayout() {
        let range = NSRange(location: 0, length: textStorage?.length ?? 0)
        invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        invalidateDisplay(forCharacterRange: range)
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
