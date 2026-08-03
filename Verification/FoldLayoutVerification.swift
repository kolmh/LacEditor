import AppKit

@main
enum FoldLayoutVerification {
    static func main() {
        let body = (1...80).map { "body-\($0)\n" }.joined()
        let source = "# Heading\n\(body)# Next\nvisible\n"
        let storage = NSTextStorage(
            string: source,
            attributes: [
                .font: NSFont.monospacedSystemFont(
                    ofSize: 14,
                    weight: .regular
                )
            ]
        )
        let layoutManager = FoldLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            containerSize: NSSize(width: 480, height: 20_000)
        )
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        let expandedHeight = layoutManager.usedRect(for: container).height
        let nextHeadingLocation = (source as NSString).range(of: "# Next").location
        let expandedNextHeadingY = layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.glyphIndexForCharacter(
                at: nextHeadingLocation
            ),
            effectiveRange: nil
        ).minY

        let bodyRange = (source as NSString).range(of: body)
        layoutManager.setFoldedRange(bodyRange)
        layoutManager.ensureLayout(for: container)
        let foldedHeight = layoutManager.usedRect(for: container).height
        let foldedNextHeadingY = layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.glyphIndexForCharacter(
                at: LogicalLineIndex.layoutAnchorCharacterIndex(
                    in: source as NSString,
                    lineRange: (source as NSString).lineRange(
                        for: NSRange(location: nextHeadingLocation, length: 0)
                    ),
                    foldedRange: layoutManager.foldedRange
                )
            ),
            effectiveRange: nil
        ).minY
        require(
            foldedHeight < expandedHeight * 0.2,
            "folded layout removes hidden line height"
        )
        require(
            foldedNextHeadingY < expandedNextHeadingY * 0.2,
            "content after the fold moves directly below the heading"
        )
        require(
            layoutManager.isCharacterFolded(bodyRange.location),
            "folded character is tracked"
        )
        require(
            !layoutManager.isCharacterFolded(NSMaxRange(bodyRange)),
            "first visible character remains outside fold"
        )

        let jsonLikeSource = "{\n  \"key\": 1\n    }\n"
        let jsonStorage = NSTextStorage(
            string: jsonLikeSource,
            attributes: [
                .font: NSFont.monospacedSystemFont(
                    ofSize: 14,
                    weight: .regular
                )
            ]
        )
        let jsonLayoutManager = FoldLayoutManager()
        jsonStorage.addLayoutManager(jsonLayoutManager)
        let jsonContainer = NSTextContainer(
            containerSize: NSSize(width: 480, height: 2_000)
        )
        jsonLayoutManager.addTextContainer(jsonContainer)
        let jsonNSString = jsonLikeSource as NSString
        let closingBraceLocation = jsonNSString.range(of: "}").location
        let jsonInteriorRange = NSRange(
            location: 1,
            length: closingBraceLocation - 1
        )
        jsonLayoutManager.setFoldedRange(jsonInteriorRange)
        jsonLayoutManager.ensureLayout(for: jsonContainer)
        let closingLineRange = jsonNSString.lineRange(
            for: NSRange(location: closingBraceLocation, length: 0)
        )
        require(
            !jsonLayoutManager.isCharacterRangeFullyFolded(closingLineRange),
            "line number remains visible when a closing delimiter is outside the fold"
        )
        let openingY = jsonLayoutManager.lineFragmentRect(
            forGlyphAt: jsonLayoutManager.glyphIndexForCharacter(at: 0),
            effectiveRange: nil
        ).minY
        let closingY = jsonLayoutManager.lineFragmentRect(
            forGlyphAt: jsonLayoutManager.glyphIndexForCharacter(
                at: LogicalLineIndex.layoutAnchorCharacterIndex(
                    in: jsonNSString,
                    lineRange: closingLineRange,
                    foldedRange: jsonLayoutManager.foldedRange
                )
            ),
            effectiveRange: nil
        ).minY
        require(
            abs(openingY - closingY) < 0.5,
            "JSON braces collapse onto one visual line"
        )
        var lineNumberTracker = LineNumberLayoutTracker()
        require(lineNumberTracker.shouldDraw(at: openingY), "first folded line number is drawn")
        require(
            !lineNumberTracker.shouldDraw(at: closingY),
            "duplicate line number on the same visual row is suppressed"
        )

        layoutManager.setFoldedRange(nil)
        layoutManager.ensureLayout(for: container)
        let restoredHeight = layoutManager.usedRect(for: container).height
        let restoredNextHeadingY = layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.glyphIndexForCharacter(
                at: LogicalLineIndex.layoutAnchorCharacterIndex(
                    in: source as NSString,
                    lineRange: (source as NSString).lineRange(
                        for: NSRange(location: nextHeadingLocation, length: 0)
                    )
                )
            ),
            effectiveRange: nil
        ).minY
        require(
            abs(restoredHeight - expandedHeight) < 0.5,
            "expanded layout restores original height"
        )
        require(
            abs(restoredNextHeadingY - expandedNextHeadingY) < 0.5,
            "expanded content returns to its original vertical position"
        )

        layoutManager.setFoldedRange(bodyRange)
        layoutManager.setFoldedRange(nil)
        storage.replaceCharacters(in: bodyRange, with: "edited\n")
        layoutManager.ensureLayout(for: container)
        require(
            layoutManager.foldedRange == nil,
            "editing after expansion does not retain stale fold state"
        )

        layoutManager.setFoldedRange(NSRange(location: 0, length: 10_000))
        require(
            layoutManager.foldedRange == NSRange(location: 0, length: storage.length),
            "fold range is clamped to current text length"
        )
        layoutManager.setFoldedRange(nil)
        storage.replaceCharacters(
            in: NSRange(location: 0, length: storage.length),
            with: "short\n"
        )
        layoutManager.ensureLayout(for: container)
        require(
            layoutManager.usedRect(for: container).height > 0,
            "large replacement after folding keeps layout valid"
        )

        print("Fold layout verification passed")
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("Verification failed: \(message)")
        }
    }
}
