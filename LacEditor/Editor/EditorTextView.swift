import AppKit
import SwiftUI

struct EditorTextView: NSViewRepresentable {
    @ObservedObject var document: EditorDocument
    let fontSize: CGFloat
    let wordWrap: Bool
    let showsLineNumbers: Bool
    let isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wordWrap
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let initialSize = scrollView.contentSize
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: wordWrap ? initialSize.width : CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textContainer.widthTracksTextView = wordWrap
        layoutManager.addTextContainer(textContainer)

        let textView = LacTextView(
            frame: NSRect(origin: .zero, size: initialSize),
            textContainer: textContainer
        )
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 18, height: 14)
        textView.backgroundColor = NSColor.lacEditorBackground
        textView.drawsBackground = true
        textView.string = document.text
        textView.font = editorFont(size: fontSize)
        textView.minSize = NSSize.zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wordWrap
        textView.autoresizingMask = NSView.AutoresizingMask.width
        scrollView.documentView = textView

        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = showsLineNumbers
        scrollView.rulersVisible = showsLineNumbers
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        ruler.lineNumberProvider = { [weak coordinator = context.coordinator] location in
            coordinator?.lineNumber(at: location) ?? 1
        }
        context.coordinator.currentFontSize = fontSize
        context.coordinator.currentLanguage = document.language
        context.coordinator.lastSynchronizedRevision = document.textRevision
        context.coordinator.installObservers(scrollView: scrollView)
        context.coordinator.updateLineNumbersVisibility(showsLineNumbers)
        context.coordinator.updateLayout(wordWrap: wordWrap, force: true)
        context.coordinator.updateActivity(isActive)
        context.coordinator.scheduleHighlight(delay: 0)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let documentChanged = context.coordinator.document.id != document.id
        let fontChanged = context.coordinator.currentFontSize != fontSize
        let languageChanged = context.coordinator.currentLanguage != document.language
        context.coordinator.document = document
        context.coordinator.currentFontSize = fontSize
        context.coordinator.currentLanguage = document.language
        context.coordinator.updateLineNumbersVisibility(showsLineNumbers)
        context.coordinator.updateActivity(isActive)

        // Marked text is owned by the input method. Replacing the string or its
        // attributes while it is composing cancels Chinese/Japanese/Korean input.
        guard !textView.hasMarkedText() else { return }

        let revisionChanged = context.coordinator.lastSynchronizedRevision
            != document.textRevision
        if documentChanged || revisionChanged {
            context.coordinator.isApplyingExternalUpdate = true
            textView.string = document.text
            context.coordinator.resetLineIndex(with: document.text)
            let textLength = (document.text as NSString).length
            let selectionLocation = min(document.selectionRange.location, textLength)
            let selectionLength = min(
                document.selectionRange.length,
                textLength - selectionLocation
            )
            textView.setSelectedRange(NSRange(
                location: selectionLocation,
                length: selectionLength
            ))
            context.coordinator.isApplyingExternalUpdate = false
            context.coordinator.lastSynchronizedRevision = document.textRevision
        }

        context.coordinator.updateLayout(wordWrap: wordWrap)
        if fontChanged {
            textView.font = editorFont(size: fontSize)
        }
        if documentChanged || revisionChanged || fontChanged || languageChanged {
            context.coordinator.scheduleHighlight(delay: 0)
        }
    }

    private func editorFont(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var document: EditorDocument
        weak var textView: LacTextView?
        weak var ruler: LineNumberRulerView?
        weak var scrollView: NSScrollView?
        var isApplyingExternalUpdate = false
        private var isApplyingAutomatedEdit = false
        var currentFontSize: CGFloat = 14
        var currentLanguage: EditorLanguage
        var lastSynchronizedRevision: UInt
        private var wordWrap = true
        private var isActive = false
        private var lineNumbersVisible: Bool?
        private var lastLayoutWidth: CGFloat = -1
        private var lastRulerWidth: CGFloat = -1
        private var highlightWorkItem: DispatchWorkItem?
        private var rulerRefreshWorkItem: DispatchWorkItem?
        private var foldedRange: NSRange?
        private var observerTokens: [NSObjectProtocol] = []
        private let lineIndex: LogicalLineIndex

        init(document: EditorDocument) {
            self.document = document
            currentLanguage = document.language
            lastSynchronizedRevision = document.textRevision
            lineIndex = LogicalLineIndex(text: document.text)
        }

        deinit {
            rulerRefreshWorkItem?.cancel()
            observerTokens.forEach(NotificationCenter.default.removeObserver)
        }

        func installObservers(scrollView: NSScrollView) {
            self.scrollView = scrollView
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.resetHorizontalScrollIfNeeded()
                self?.ruler?.needsDisplay = true
                self?.scheduleHighlight()
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                updateLayout(wordWrap: wordWrap)
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: EditorCommandNotification.revealSelection,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let request = notification.object as? EditorSelectionRequest,
                      request.documentID == document.id,
                      let textView else { return }
                let length = (textView.string as NSString).length
                let range = NSIntersectionRange(
                    request.range,
                    NSRange(location: 0, length: length)
                )
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
                textView.window?.makeFirstResponder(textView)
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: EditorCommandNotification.toggleFold,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      notification.object as? UUID == document.id else { return }
                toggleFold()
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: EditorCommandNotification.undo,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      notification.object as? UUID == document.id else { return }
                textView?.undoManager?.undo()
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: EditorCommandNotification.redo,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      notification.object as? UUID == document.id else { return }
                textView?.undoManager?.redo()
            })
        }

        func updateLayout(wordWrap: Bool, force: Bool = false) {
            guard let scrollView, let textView, let textContainer = textView.textContainer else { return }
            let contentSize = scrollView.contentSize
            let availableWidth = max(1, contentSize.width)
            let rulerWidth = scrollView.rulersVisible
                ? (scrollView.verticalRulerView?.ruleThickness ?? 0)
                : 0
            guard force
                    || self.wordWrap != wordWrap
                    || abs(lastLayoutWidth - availableWidth) > 0.5
                    || abs(lastRulerWidth - rulerWidth) > 0.5
            else {
                return
            }
            self.wordWrap = wordWrap
            lastLayoutWidth = availableWidth
            lastRulerWidth = rulerWidth
            let documentWidth = max(1, availableWidth - rulerWidth)
            let usableTextWidth = max(
                1,
                documentWidth - (textView.textContainerInset.width * 2)
            )

            // The text container is managed explicitly so its line fragments
            // stop before the preview divider, including both horizontal insets.
            textContainer.widthTracksTextView = false
            textContainer.containerSize = NSSize(
                width: wordWrap ? usableTextWidth : CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.isHorizontallyResizable = !wordWrap
            textView.autoresizingMask = wordWrap ? [.width] : []
            textView.minSize = NSSize(width: 0, height: contentSize.height)
            textView.maxSize = NSSize(
                width: wordWrap ? documentWidth : CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.frame.origin.x = rulerWidth
            if wordWrap {
                textView.frame.size.width = documentWidth
            } else if textView.frame.width < documentWidth {
                textView.frame.size.width = documentWidth
            }
            scrollView.hasHorizontalScroller = !wordWrap
            scrollView.horizontalScrollElasticity = wordWrap ? .none : .automatic
            resetHorizontalScrollIfNeeded()
            textView.needsDisplay = true
            ensureVisibleLayout()
            scheduleRulerRefreshAfterResize()
        }

        private func scheduleRulerRefreshAfterResize() {
            rulerRefreshWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let ruler = self?.ruler else { return }
                ruler.invalidateHashMarks()
                ruler.setNeedsDisplay(ruler.bounds)
            }
            rulerRefreshWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.12,
                execute: workItem
            )
        }

        private func resetHorizontalScrollIfNeeded() {
            guard wordWrap,
                  let scrollView,
                  scrollView.contentView.bounds.origin.x != 0 else { return }
            let y = scrollView.contentView.bounds.origin.y
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        func updateLineNumbersVisibility(_ isVisible: Bool) {
            guard let scrollView else { return }
            guard lineNumbersVisible != isVisible else { return }
            lineNumbersVisible = isVisible
            scrollView.hasVerticalRuler = isVisible
            scrollView.rulersVisible = isVisible
            lastRulerWidth = -1
            ruler?.needsDisplay = true
        }

        func updateActivity(_ newValue: Bool) {
            guard isActive != newValue else { return }
            isActive = newValue
            guard newValue else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, isActive, let textView, let window = textView.window else {
                    return
                }
                window.makeFirstResponder(textView)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalUpdate, let textView else { return }
            if lineIndex.textLength != (textView.string as NSString).length {
                lineIndex.reset(with: textView.string)
            }
            document.text = textView.string
            lastSynchronizedRevision = document.textRevision
            document.refreshDirtyState()
            document.statusMessage = nil
            if let existing = foldedRange,
               let layoutManager = textView.layoutManager {
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: existing,
                    actualCharacterRange: nil
                )
                if glyphRange.length > 0 {
                    for glyph in glyphRange.location..<NSMaxRange(glyphRange) {
                        layoutManager.setNotShownAttribute(false, forGlyphAt: glyph)
                    }
                }
            }
            foldedRange = nil
            refreshRuler()
            updateCursor()
            scheduleHighlight()
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            let replacement = replacementString ?? ""
            let nsText = textView.string as NSString
            let safeLocation = min(affectedCharRange.location, nsText.length)
            let safeRange = NSRange(
                location: safeLocation,
                length: min(
                    affectedCharRange.length,
                    nsText.length - safeLocation
                )
            )

            if isApplyingAutomatedEdit {
                lineIndex.applyEdit(range: safeRange, replacement: replacement)
                return true
            }
            guard document.language == .markdown else {
                lineIndex.applyEdit(range: safeRange, replacement: replacement)
                return true
            }

            guard ListContinuationService.shouldNormalizeOrderedListEdit(
                    in: textView.string,
                    range: safeRange,
                    replacement: replacement
                  ),
                  !ListContinuationService.isManualOrderedMarkerEdit(
                    in: textView.string,
                    range: safeRange,
                    replacement: replacement
                  ) else {
                lineIndex.applyEdit(range: safeRange, replacement: replacement)
                return true
            }

            let prospectiveText = NSMutableString(string: textView.string)
            prospectiveText.replaceCharacters(in: safeRange, with: replacement)
            let intendedCaretLocation = safeRange.location
                + (replacement as NSString).length
            guard let normalization = ListContinuationService.normalizeOrderedList(
                in: prospectiveText as String,
                aroundUTF16Location: intendedCaretLocation
            ), let combinedEdit = combinedEdit(
                from: textView.string,
                to: normalization.text
            ) else {
                lineIndex.applyEdit(range: safeRange, replacement: replacement)
                return true
            }

            isApplyingAutomatedEdit = true
            textView.insertText(
                combinedEdit.replacement,
                replacementRange: combinedEdit.range
            )
            textView.setSelectedRange(NSRange(
                location: normalization.mappedLocation(for: intendedCaretLocation),
                length: 0
            ))
            isApplyingAutomatedEdit = false
            return false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard textView?.hasMarkedText() != true else { return }
            updateCursor()
            textView?.needsDisplay = true
        }

        func scheduleHighlight(delay: TimeInterval = 0.12) {
            highlightWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.applyHighlight(fontSize: self?.currentFontSize ?? 14) }
            highlightWorkItem = work
            if delay <= 0 {
                DispatchQueue.main.async(execute: work)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }

        func applyHighlight(fontSize: CGFloat) {
            guard let textView,
                  !textView.hasMarkedText(),
                  let storage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            let highlightRange = storage.length > 500_000 ? visibleHighlightRange() : nil
            SyntaxHighlighter.apply(
                to: storage,
                language: document.language,
                baseFont: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                range: highlightRange
            )
            textView.setSelectedRange(selection)
            refreshRuler()
        }

        private func updateCursor() {
            guard let textView else { return }
            let selection = textView.selectedRange()
            document.selectionRange = selection
            let location = min(selection.location, (textView.string as NSString).length)
            let position = lineIndex.position(
                at: location,
                in: textView.string as NSString
            )
            document.cursorLine = position.line
            document.cursorColumn = position.column
        }

        private func combinedEdit(
            from original: String,
            to replacement: String
        ) -> (range: NSRange, replacement: String)? {
            let oldText = original as NSString
            let newText = replacement as NSString
            guard !oldText.isEqual(to: replacement) else { return nil }

            let sharedLimit = min(oldText.length, newText.length)
            var prefixLength = 0
            while prefixLength < sharedLimit,
                  oldText.character(at: prefixLength) == newText.character(at: prefixLength) {
                prefixLength += 1
            }

            var suffixLength = 0
            while suffixLength < oldText.length - prefixLength,
                  suffixLength < newText.length - prefixLength,
                  oldText.character(at: oldText.length - suffixLength - 1)
                    == newText.character(at: newText.length - suffixLength - 1) {
                suffixLength += 1
            }

            let oldRange = NSRange(
                location: prefixLength,
                length: oldText.length - prefixLength - suffixLength
            )
            let newRange = NSRange(
                location: prefixLength,
                length: newText.length - prefixLength - suffixLength
            )
            return (oldRange, newText.substring(with: newRange))
        }

        private func refreshRuler() {
            guard textView != nil else { return }
            ensureVisibleLayout()
            ruler?.invalidateHashMarks()
            ruler?.needsDisplay = true

            // NSTextView finishes creating the extra line fragment after the
            // change notification. Refresh once more on the next run loop.
            DispatchQueue.main.async { [weak self] in
                self?.ruler?.invalidateHashMarks()
                self?.ruler?.needsDisplay = true
            }
        }

        func resetLineIndex(with text: String) {
            lineIndex.reset(with: text)
        }

        func lineNumber(at location: Int) -> Int {
            lineIndex.lineNumber(at: location)
        }

        private func ensureVisibleLayout() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return
            }
            let visibleRect = textView.visibleRect.offsetBy(
                dx: -textView.textContainerOrigin.x,
                dy: -textView.textContainerOrigin.y
            )
            layoutManager.ensureLayout(
                forBoundingRect: visibleRect,
                in: textContainer
            )
        }

        private func visibleHighlightRange() -> NSRange? {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return nil }
            let visibleRect = textView.visibleRect.offsetBy(
                dx: -textView.textContainerOrigin.x,
                dy: -textView.textContainerOrigin.y
            )
            let glyphRange = layoutManager.glyphRange(
                forBoundingRect: visibleRect,
                in: textContainer
            )
            let characterRange = layoutManager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )
            let padding = 4_000
            let start = max(0, characterRange.location - padding)
            let end = min(
                (textView.string as NSString).length,
                NSMaxRange(characterRange) + padding
            )
            return NSRange(location: start, length: max(0, end - start))
        }

        private func toggleFold() {
            guard let textView, textView.window?.firstResponder === textView,
                  let layoutManager = textView.layoutManager else { return }
            if let existing = foldedRange {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: existing, actualCharacterRange: nil)
                for glyph in glyphRange.location..<NSMaxRange(glyphRange) {
                    layoutManager.setNotShownAttribute(false, forGlyphAt: glyph)
                }
                foldedRange = nil
            } else if let range = FoldService.foldableRange(
                in: textView.string,
                at: textView.selectedRange().location,
                language: document.language
            ) {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                for glyph in glyphRange.location..<NSMaxRange(glyphRange) {
                    layoutManager.setNotShownAttribute(true, forGlyphAt: glyph)
                }
                foldedRange = range
            }
            textView.needsDisplay = true
            ruler?.needsDisplay = true
        }
    }
}
