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
                alpha: 0.14
            )
        }
        return NSColor(
            calibratedRed: 0.31,
            green: 0.34,
            blue: 0.66,
            alpha: 0.07
        )
    }

    static let lacDelimiterMatchBackground = NSColor(name: nil) { appearance in
        let alpha: CGFloat = appearance.bestMatch(from: [.darkAqua, .aqua])
            == .darkAqua ? 0.24 : 0.14
        return NSColor.controlAccentColor.withAlphaComponent(alpha)
    }
}

final class LacTextView: NSTextView {
    var currentLineColor: NSColor = .lacCurrentLineBackground
    var selectionTrackingHandler: (() -> Void)?
    var requestsFirstResponderWhenAttached = false
    var textTransformationHandler: ((TextTransformationOperation) -> Void)?

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

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if !menu.items.isEmpty { menu.addItem(.separator()) }

        let root = NSMenuItem(
            title: "编码与解码",
            action: nil,
            keyEquivalent: ""
        )
        root.image = NSImage(
            systemSymbolName: "arrow.left.arrow.right",
            accessibilityDescription: "编码与解码"
        )
        let submenu = NSMenu(title: "编码与解码")
        if let text = textStorage?.mutableString,
           let candidate = TextCodecService.candidate(
               in: text,
               selection: selectedRange(),
               allowsTokenAtCaret: true,
               maximumLength: TextCodecService.automaticDetectionLimit
           ),
           let detection = TextCodecService.detect(
               in: candidate.text,
               allowsBase64: selectedRange().length > 0
           ) {
            submenu.addItem(transformationMenuItem(
                "智能解码（\(detection.kind.rawValue)）",
                operation: .smartDecode
            ))
            submenu.addItem(.separator())
        }

        submenu.addItem(categoryMenuItem(
            title: "URL",
            operations: [.urlEncodeComponent, .urlDecode, .formURLDecode]
        ))
        submenu.addItem(categoryMenuItem(
            title: "Base64",
            operations: [
                .base64Encode, .base64Decode,
                .base64URLEncode, .base64URLDecode
            ]
        ))
        submenu.addItem(categoryMenuItem(
            title: "HTML 实体",
            operations: [.htmlEncode, .htmlDecode]
        ))
        submenu.addItem(categoryMenuItem(
            title: "Unicode/JSON 转义",
            operations: [.unicodeEncode, .unicodeDecode]
        ))
        root.submenu = submenu
        menu.addItem(root)
        return menu
    }

    @objc
    private func performTextTransformation(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let operation = TextTransformationOperation(rawValue: rawValue) else { return }
        textTransformationHandler?(operation)
    }

    private func categoryMenuItem(
        title: String,
        operations: [TextTransformationOperation]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        operations.forEach {
            submenu.addItem(transformationMenuItem($0.title, operation: $0))
        }
        item.submenu = submenu
        return item
    }

    private func transformationMenuItem(
        _ title: String,
        operation: TextTransformationOperation
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(performTextTransformation(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = operation.rawValue
        return item
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
