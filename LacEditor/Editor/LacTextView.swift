import AppKit

extension NSColor {
    static let lacEditorBackground = NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [.darkAqua, .aqua])
        if match == .darkAqua {
            return NSColor(calibratedWhite: 0.105, alpha: 1)
        }
        return NSColor(
            red: 251.0 / 255.0,
            green: 251.0 / 255.0,
            blue: 251.0 / 255.0,
            alpha: 1
        )
    }

    static let lacCurrentLineBackground = NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [.darkAqua, .aqua])
        if match == .darkAqua {
            return NSColor(
                calibratedRed: 0.48,
                green: 0.53,
                blue: 0.88,
                alpha: 0.16
            )
        }
        return NSColor(
            calibratedRed: 0.31,
            green: 0.34,
            blue: 0.66,
            alpha: 0.065
        )
    }
}

final class LacTextView: NSTextView {
    var currentLineColor: NSColor = .lacCurrentLineBackground
    var selectionTrackingHandler: (() -> Void)?
    var requestsFirstResponderWhenAttached = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard requestsFirstResponderWhenAttached,
              let window else { return }
        window.makeFirstResponder(self)
    }

    override func setSelectedRange(
        _ charRange: NSRange,
        affinity: NSSelectionAffinity,
        stillSelecting flag: Bool
    ) {
        super.setSelectedRange(
            charRange,
            affinity: affinity,
            stillSelecting: flag
        )
        if flag {
            selectionTrackingHandler?()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        if let layoutManager {
            layoutManager.invalidateDisplay(
                forCharacterRange: NSRange(
                    location: 0,
                    length: textStorage?.length ?? 0
                )
            )
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager,
              textContainer != nil,
              let text = textStorage?.mutableString else { return }
        let location = min(selectedRange().location, text.length)
        let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: lineRange,
            actualCharacterRange: nil
        )
        var lineRects: [NSRect] = []
        if glyphRange.length == 0, location == text.length {
            var lineRect = layoutManager.extraLineFragmentRect
            if lineRect.isEmpty {
                lineRect = NSRect(
                    x: 0,
                    y: textContainerInset.height,
                    width: bounds.width,
                    height: defaultParagraphStyle?.maximumLineHeight ?? 18
                )
            }
            lineRects.append(lineRect)
        } else {
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
                lineRect,
                _,
                _,
                _,
                _ in
                lineRects.append(lineRect)
            }
        }
        currentLineColor.setFill()
        for var lineRect in lineRects {
            lineRect.origin.x = 0
            lineRect.origin.y += textContainerOrigin.y
            lineRect.size.width = bounds.width
            lineRect.intersection(rect).fill()
        }
    }

    override func insertTab(_ sender: Any?) {
        insertText("    ", replacementRange: selectedRange())
    }

    override func insertNewline(_ sender: Any?) {
        guard let nsString = textStorage?.mutableString else {
            super.insertNewline(sender)
            return
        }
        let selection = selectedRange()
        let lineRange = nsString.lineRange(for: NSRange(location: selection.location, length: 0))
        let linePrefix = nsString.substring(with: NSRange(
            location: lineRange.location,
            length: max(0, min(selection.location - lineRange.location, lineRange.length))
        ))
        let indentation = String(linePrefix.prefix { $0 == " " || $0 == "\t" })
        let trimmed = linePrefix.trimmingCharacters(in: .whitespaces)
        let continuation: String
        if trimmed.hasSuffix("{") || trimmed.hasSuffix("[") {
            continuation = "    "
        } else {
            continuation = ListContinuationService.continuation(for: linePrefix) ?? ""
        }

        if ListContinuationService.isEmptyListItem(linePrefix) {
            let replacementRange = NSRange(
                location: lineRange.location,
                length: selection.location - lineRange.location
            )
            insertText("\n\(indentation)", replacementRange: replacementRange)
            return
        }
        insertText("\n\(indentation)\(continuation)", replacementRange: selection)
    }
}
