import AppKit

enum IndentationStyle: String, CaseIterable, Identifiable {
    case spaces
    case tabs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spaces: "使用空格"
        case .tabs: "使用 Tab 字符"
        }
    }
}

func lacEditorFont(size: CGFloat) -> NSFont {
    // Menlo supplies stable fixed-width metrics for Latin text. AppKit uses
    // the system fallback (PingFang on Chinese systems) for glyphs Menlo does
    // not contain. FoldLayoutManager deliberately keeps line metrics based on
    // this requested font rather than whichever fallback draws the first glyph.
    NSFont(name: "Menlo-Regular", size: size)
        ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

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
    var indentationStyle: IndentationStyle = .spaces
    var tabWidth: Int = 4
    var editorLineSpacing: CGFloat = FoldLayoutManager.defaultLineSpacing
    private var paragraphRefreshGeneration: UInt = 0
    private var paragraphRefreshLocation = 0
    private var paragraphRefreshWorkItem: DispatchWorkItem?

    var editorLineHeight: CGFloat {
        (layoutManager as? FoldLayoutManager)?.editorLineHeight
            ?? ((font?.pointSize ?? 14) + editorLineSpacing)
    }


    var currentLineColor: NSColor = .lacCurrentLineBackground
    var selectionTrackingHandler: (() -> Void)?
    var requestsFirstResponderWhenAttached = false
    var textTransformationHandler: ((TextTransformationOperation) -> Void)?
    var listIndentationHandler: ((Bool) -> Bool)?

    /// NSTextView normally reports the fallback font used by the first glyph.
    /// When a document starts with Chinese, that can be PingFang even though
    /// the requested editor font is Menlo. Always expose the requested font so
    /// typing and tab metrics cannot change with the first character.
    override var font: NSFont? {
        get {
            (layoutManager as? FoldLayoutManager)?.textFont ?? super.font
        }
        set {
            guard let newValue else { return }
            (layoutManager as? FoldLayoutManager)?.textFont = newValue
            super.font = newValue
            typingAttributes[.font] = newValue
        }
    }

    override func keyDown(with event: NSEvent) {
        // Handle the physical Tab key before AppKit applies its paragraph
        // indentation command. This is especially important at column zero.
        if event.keyCode == 48, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            if listIndentationHandler?(false) == true { return }
            insertTab(nil)
            return
        }
        if event.keyCode == 48, event.modifierFlags.contains(.shift),
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            if listIndentationHandler?(true) == true { return }
            insertBacktab(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        // TextKit represents a final empty line (the line after a trailing
        // newline) as an extra line fragment without a character range. Its
        // default hit testing maps clicks in that fragment back to the
        // preceding newline, which makes the last visible line impossible to
        // place the caret in from the editor area. Treat the fragment as the
        // document-end insertion point before falling back to AppKit.
        if let layoutManager,
           let storage = textStorage,
           storage.length > 0,
           storage.mutableString.character(at: storage.length - 1)
                == 10,
           !layoutManager.extraLineFragmentRect.isEmpty {
            let point = convert(event.locationInWindow, from: nil)
            var extraRect = layoutManager.extraLineFragmentRect
            extraRect.origin.x += textContainerOrigin.x
            extraRect.origin.y += textContainerOrigin.y
            extraRect.size.width = max(bounds.width, extraRect.width)
            if extraRect.insetBy(dx: 0, dy: -2).contains(point) {
                window?.makeFirstResponder(self)
                setSelectedRange(NSRange(location: storage.length, length: 0))
                return
            }
        }
        super.mouseDown(with: event)
    }

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
                    height: editorLineHeight
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
        let indentation = indentationStyle == .tabs
            ? "\t"
            : String(repeating: " ", count: tabWidth)
        let range = selectedRange()
        // Replace directly instead of routing through AppKit's tab command,
        // which may briefly apply its own paragraph indentation at column 0.
        replaceCharacters(in: range, with: indentation)
        setSelectedRange(NSRange(
            location: range.location + (indentation as NSString).length,
            length: 0
        ))
    }

    override func doCommand(by selector: Selector) {
        // NSTextView may dispatch Tab through the command chain as well as
        // insertTab(_:). Handle it exactly once to avoid the visible bounce.
        if selector == #selector(insertTab(_:)) {
            if listIndentationHandler?(false) == true { return }
            insertTab(nil)
            return
        }
        if selector == #selector(insertBacktab(_:)) {
            if listIndentationHandler?(true) == true { return }
            insertBacktab(nil)
            return
        }
        super.doCommand(by: selector)
    }

    override func insertBacktab(_ sender: Any?) {
        let range = selectedRange()
        guard range.length == 0, range.location > 0,
              let text = textStorage?.string as NSString? else {
            super.insertBacktab(sender)
            return
        }
        let line = text.lineRange(for: NSRange(location: range.location, length: 0))
        let beforeCaret = NSRange(location: line.location, length: range.location - line.location)
        let prefix = text.substring(with: beforeCaret)
        let removeCount: Int
        if prefix.hasSuffix("\t") {
            removeCount = 1
        } else {
            removeCount = min(tabWidth, prefix.reversed().prefix { $0 == " " }.count)
        }
        guard removeCount > 0 else { return }
        replaceCharacters(in: NSRange(
            location: range.location - removeCount,
            length: removeCount
        ), with: "")
        setSelectedRange(NSRange(location: range.location - removeCount, length: 0))
    }

    func configureTabStops() {
        let paragraphStyle = (typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
            as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        let displayFont = self.font ?? lacEditorFont(size: 14)
        let width = displayFont.maximumAdvancement.width * CGFloat(tabWidth)
        paragraphStyle.defaultTabInterval = width
        paragraphStyle.tabStops = []
        // The layout manager is the sole owner of line height. Paragraph-level
        // min/max heights are intentionally cleared because input methods can
        // replace the first run's font during composition.
        paragraphStyle.minimumLineHeight = 0
        paragraphStyle.maximumLineHeight = 0
        paragraphStyle.lineHeightMultiple = 1
        paragraphStyle.lineSpacing = 0
        typingAttributes[.font] = displayFont
        typingAttributes[.foregroundColor] = NSColor.labelColor
        typingAttributes[.paragraphStyle] = paragraphStyle
        defaultParagraphStyle = paragraphStyle
        enclosingScrollView?.lineScroll = editorLineHeight
    }

    /// Apply paragraph attributes in cancellable chunks so large documents do
    /// not block typing and window resizing for one long main-thread turn.
    func scheduleParagraphStyleRefresh(chunkSize: Int = 32 * 1_024) {
        paragraphRefreshWorkItem?.cancel()
        paragraphRefreshGeneration &+= 1
        paragraphRefreshLocation = 0
        let generation = paragraphRefreshGeneration
        let work = DispatchWorkItem { [weak self] in
            self?.applyParagraphStyleChunk(
                generation: generation,
                chunkSize: chunkSize
            )
        }
        paragraphRefreshWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func applyParagraphStyleChunk(
        generation: UInt,
        chunkSize: Int
    ) {
        guard generation == paragraphRefreshGeneration,
              paragraphRefreshWorkItem?.isCancelled != true,
              let storage = textStorage,
              let style = defaultParagraphStyle,
              storage.length > 0 else {
            paragraphRefreshWorkItem = nil
            return
        }
        let start = min(paragraphRefreshLocation, storage.length)
        let end = min(storage.length, start + max(1, chunkSize))
        guard end > start else {
            paragraphRefreshWorkItem = nil
            return
        }
        storage.addAttribute(
            .paragraphStyle,
            value: style,
            range: NSRange(location: start, length: end - start)
        )
        paragraphRefreshLocation = end
        if end < storage.length {
            let next = DispatchWorkItem { [weak self] in
                self?.applyParagraphStyleChunk(
                    generation: generation,
                    chunkSize: chunkSize
                )
            }
            paragraphRefreshWorkItem = next
            DispatchQueue.main.async(execute: next)
        } else {
            paragraphRefreshWorkItem = nil
        }
    }

    func cancelParagraphStyleRefresh() {
        paragraphRefreshWorkItem?.cancel()
        paragraphRefreshWorkItem = nil
        paragraphRefreshGeneration &+= 1
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
            continuation = indentationUnit
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

    private var indentationUnit: String {
        indentationStyle == .tabs ? "\t" : String(repeating: " ", count: tabWidth)
    }
}
