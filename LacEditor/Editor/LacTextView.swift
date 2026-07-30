import AppKit

extension NSColor {
    static let lacEditorBackground = NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [.darkAqua, .aqua])
        if match == .darkAqua {
            return NSColor(calibratedWhite: 0.105, alpha: 1)
        }
        return NSColor(red: 0.992, green: 0.988, blue: 0.975, alpha: 1)
    }
}

final class LacTextView: NSTextView {
    var currentLineColor: NSColor = .selectedContentBackgroundColor.withAlphaComponent(0.055)

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, textContainer != nil else { return }
        let location = min(selectedRange().location, (string as NSString).length)
        let lineRange = (string as NSString).lineRange(for: NSRange(location: location, length: 0))
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: lineRange,
            actualCharacterRange: nil
        )
        var lineRect: NSRect
        if glyphRange.length == 0, location == (string as NSString).length {
            lineRect = layoutManager.extraLineFragmentRect
            if lineRect.isEmpty {
                lineRect = NSRect(
                    x: 0,
                    y: textContainerInset.height,
                    width: bounds.width,
                    height: defaultParagraphStyle?.maximumLineHeight ?? 18
                )
            }
        } else {
            lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
        }
        lineRect.origin.x = 0
        lineRect.origin.y += textContainerOrigin.y
        lineRect.size.width = bounds.width
        currentLineColor.setFill()
        lineRect.intersection(rect).fill()
    }

    override func insertTab(_ sender: Any?) {
        insertText("    ", replacementRange: selectedRange())
    }

    override func insertNewline(_ sender: Any?) {
        let nsString = string as NSString
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
