import AppKit
import os
import SwiftUI

private let editorPerformanceLog = OSLog(
    subsystem: "com.laceditor.LacEditor",
    category: "EditorPerformance"
)

struct EditorTextView: NSViewRepresentable {
    @ObservedObject var document: EditorDocument
    let sessionStore: EditorSessionStore
    let fontSize: CGFloat
    let wordWrap: Bool
    let showsLineNumbers: Bool
    let topInset: CGFloat
    let isActive: Bool
    let requestTextTransformation: (TextTransformationOperation) -> Void

    func makeCoordinator() -> Coordinator {
        sessionStore.coordinator(for: document)
    }

    func makeNSView(context: Context) -> NSScrollView {
        if let cachedView = sessionStore.cachedView(for: document.id) {
            os_signpost(
                .event,
                log: editorPerformanceLog,
                name: "EditorSessionReattach"
            )
            return cachedView
        }
        let createSignpostID = OSSignpostID(log: editorPerformanceLog)
        os_signpost(
            .begin,
            log: editorPerformanceLog,
            name: "EditorSessionCreate",
            signpostID: createSignpostID
        )
        defer {
            os_signpost(
                .end,
                log: editorPerformanceLog,
                name: "EditorSessionCreate",
                signpostID: createSignpostID
            )
        }
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wordWrap
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textStorage = NSTextStorage()
        let layoutManager = FoldLayoutManager()
        layoutManager.allowsNonContiguousLayout = document.isLargeFileMode
        layoutManager.backgroundLayoutEnabled = !document.isLargeFileMode
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
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 0, height: topInset)
        textContainer.lineFragmentPadding = 0
        textView.backgroundColor = NSColor.lacEditorBackground
        textView.drawsBackground = true
        textView.string = document.text
        let textLength = (document.text as NSString).length
        let selectionLocation = min(document.selectionRange.location, textLength)
        textView.setSelectedRange(NSRange(
            location: selectionLocation,
            length: min(
                document.selectionRange.length,
                textLength - selectionLocation
            )
        ))
        textView.delegate = context.coordinator
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
        context.coordinator.foldLayoutManager = layoutManager
        context.coordinator.ruler = ruler
        context.coordinator.attachLiveTextProvider()
        textView.selectionTrackingHandler = { [weak coordinator = context.coordinator] in
            coordinator?.selectionDidChangeDuringTracking()
        }
        textView.textTransformationHandler = requestTextTransformation
        ruler.lineNumberProvider = { [weak coordinator = context.coordinator] location in
            coordinator?.lineNumber(at: location) ?? 1
        }
        context.coordinator.currentFontSize = fontSize
        context.coordinator.currentLanguage = document.language
        context.coordinator.updatePerformanceFeatures()
        context.coordinator.lastSynchronizedRevision = document.textRevision
        context.coordinator.installObservers(scrollView: scrollView)
        context.coordinator.updateLineNumbersVisibility(showsLineNumbers)
        context.coordinator.updateLayout(wordWrap: wordWrap, force: true)
        context.coordinator.updateActivity(isActive)
        context.coordinator.synchronizeSelectionState()
        context.coordinator.scheduleHighlight(delay: 0)
        context.coordinator.restoreViewportState()
        sessionStore.store(
            scrollView,
            coordinator: context.coordinator,
            for: document.id
        )
        return scrollView
    }

    static func dismantleNSView(
        _ scrollView: NSScrollView,
        coordinator: Coordinator
    ) {
        coordinator.flushModelText(reconcileDirtyState: true)
        coordinator.updateActivity(false)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.textTransformationHandler = requestTextTransformation
        let documentChanged = context.coordinator.document.id != document.id
        let fontChanged = context.coordinator.currentFontSize != fontSize
        let languageChanged = context.coordinator.currentLanguage != document.language
        if documentChanged || languageChanged {
            context.coordinator.resetSyntaxHighlightContext()
        }
        context.coordinator.document = document
        context.coordinator.currentFontSize = fontSize
        context.coordinator.currentLanguage = document.language
        context.coordinator.updatePerformanceFeatures()
        context.coordinator.updateLineNumbersVisibility(showsLineNumbers)
        context.coordinator.updateTopInset(topInset)
        context.coordinator.updateActivity(isActive)

        // Marked text is owned by the input method. Replacing the string or its
        // attributes while it is composing cancels Chinese/Japanese/Korean input.
        guard !textView.hasMarkedText() else { return }

        let revisionChanged = context.coordinator.lastSynchronizedRevision
            != document.textRevision
        if documentChanged || revisionChanged {
            if revisionChanged, !documentChanged {
                context.coordinator.resetSyntaxHighlightContext()
            }
            context.coordinator.advanceContentRevision()
            context.coordinator.isApplyingExternalUpdate = true
            context.coordinator.clearFold()
            let requestedSelection = document.selectionRange
            textView.string = document.text
            context.coordinator.resetLineIndex(with: document.text)
            let textLength = (document.text as NSString).length
            let selectionLocation = min(requestedSelection.location, textLength)
            let selectionLength = min(
                requestedSelection.length,
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
        if documentChanged || revisionChanged || languageChanged {
            context.coordinator.scheduleDelimiterMatch(delay: 0)
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
        weak var foldLayoutManager: FoldLayoutManager?
        var isApplyingExternalUpdate = false
        private var isApplyingAutomatedEdit = false
        private var isRestoringOffscreenEdit = false
        var currentFontSize: CGFloat = 14
        var currentLanguage: EditorLanguage
        var lastSynchronizedRevision: UInt
        private var wordWrap = true
        private var isActive = false
        private var syntaxHighlightingEnabled: Bool
        private var clearsDisabledSyntaxOnScroll = false
        private var lineNumbersVisible: Bool?
        private var lastLayoutWidth: CGFloat = -1
        private var lastRulerWidth: CGFloat = -1
        private var highlightWorkItem: DispatchWorkItem?
        private let highlightQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "com.laceditor.syntax-highlighting"
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            return queue
        }()
        private var highlightOperation: BlockOperation?
        private let syntaxHighlightContext = SyntaxHighlighter.IncrementalContext()
        private let delimiterMatchingContext = DelimiterMatchingService.Context()
        private var delimiterMatchWorkItem: DispatchWorkItem?
        private let delimiterMatchQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "com.laceditor.delimiter-matching"
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            return queue
        }()
        private var delimiterMatchOperation: BlockOperation?
        private var delimiterSnapshot: String?
        private var delimiterSnapshotRevision: UInt?
        private var delimiterHighlightRanges: [NSRange] = []
        private var highlightGeneration: UInt = 0
        private var contentRevision: UInt
        private var highlightedRevision: UInt?
        private var highlightedLanguage: EditorLanguage?
        private var highlightedFontSize: CGFloat?
        private var highlightedRange: NSRange?
        private var rulerRefreshWorkItem: DispatchWorkItem?
        private var rulerResizeRefreshWorkItem: DispatchWorkItem?
        private var rulerRefreshNeedsLayout = false
        private var selectionVisibilityWorkItem: DispatchWorkItem?
        private var textCodecSuggestionWorkItem: DispatchWorkItem?
        private var modelSyncWorkItem: DispatchWorkItem?
        private var layoutPrefetchWorkItem: DispatchWorkItem?
        private var listNormalizationWorkItem: DispatchWorkItem?
        private let listNormalizationQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "com.laceditor.list-normalization"
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            return queue
        }()
        private var pendingListNormalizationLocation: Int?
        private var lastViewportOriginY: CGFloat = 0
        private let liveTextProviderID = UUID()
        private var pendingSelectionScrollOriginY: CGFloat?
        private var pendingOffscreenEditAnchor: Int?
        private var pendingOffscreenSelectionRange: NSRange?
        private var observerTokens: [NSObjectProtocol] = []
        private let lineIndex: LogicalLineIndex

        init(document: EditorDocument) {
            self.document = document
            currentLanguage = document.language
            lastSynchronizedRevision = document.textRevision
            contentRevision = document.textRevision
            lineIndex = LogicalLineIndex(text: document.text)
            syntaxHighlightingEnabled = document.isSyntaxHighlightingEnabled
        }

        var isSessionActive: Bool { isActive }

        var estimatedMemoryCost: Int {
            let utf16Bytes = (textView?.textStorage?.length ?? document.text.utf16.count) * 2
            return utf16Bytes * 4
        }

        func prepareForEviction() {
            flushModelText(reconcileDirtyState: true)
            if let scrollView {
                let contentHeight = max(
                    1,
                    (scrollView.documentView?.bounds.height ?? 0)
                        - scrollView.contentView.bounds.height
                )
                document.scrollPositionRatio = min(
                    1,
                    max(0, scrollView.contentView.bounds.minY / contentHeight)
                )
            }
            document.foldedRange = foldLayoutManager?.foldedRange
        }

        func restoreViewportState() {
            guard let scrollView else { return }
            let ratio = document.scrollPositionRatio
            DispatchQueue.main.async { [weak scrollView] in
                guard let scrollView, ratio > 0 else { return }
                let contentHeight = max(
                    0,
                    (scrollView.documentView?.bounds.height ?? 0)
                        - scrollView.contentView.bounds.height
                )
                scrollView.contentView.scroll(
                    to: NSPoint(x: 0, y: contentHeight * ratio)
                )
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        deinit {
            modelSyncWorkItem?.cancel()
            layoutPrefetchWorkItem?.cancel()
            listNormalizationWorkItem?.cancel()
            listNormalizationQueue.cancelAllOperations()
            document.detachLiveTextProvider(id: liveTextProviderID)
            highlightWorkItem?.cancel()
            highlightOperation?.cancel()
            highlightQueue.cancelAllOperations()
            delimiterMatchWorkItem?.cancel()
            delimiterMatchOperation?.cancel()
            delimiterMatchQueue.cancelAllOperations()
            document.taskCoordinator.cancel(.delimiterMatch)
            rulerRefreshWorkItem?.cancel()
            rulerResizeRefreshWorkItem?.cancel()
            selectionVisibilityWorkItem?.cancel()
            textCodecSuggestionWorkItem?.cancel()
            observerTokens.forEach(NotificationCenter.default.removeObserver)
        }

        func installObservers(scrollView: NSScrollView) {
            self.scrollView = scrollView
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                guard let self, isActive else { return }
                resetHorizontalScrollIfNeeded()
                refreshRulerForViewportChange()
                scheduleHighlight()
                scheduleDirectionalLayoutPrefetch()
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                guard let self, isActive else { return }
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
                clearFoldIfNeeded(toReveal: request.range)
                let length = textView.textStorage?.length ?? 0
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
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: EditorCommandNotification.applyTextUpdate,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let request = notification.object as? EditorTextUpdateRequest,
                      request.documentID == document.id,
                      let textView else { return }
                apply(request, to: textView)
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: EditorCommandNotification.extractTextSelection,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let request = notification.object as? EditorTextExtractionRequest,
                      request.documentID == document.id else { return }
                extractSelection(for: request)
            })
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: EditorCommandNotification.applyRangeReplacement,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let request = notification.object as? EditorRangeReplacementRequest,
                      request.documentID == document.id,
                      let textView else { return }
                apply(request, to: textView)
            })
        }

        func attachLiveTextProvider() {
            document.attachLiveTextProvider(
                id: liveTextProviderID,
                provider: { [weak textView] in textView?.string },
                acknowledgement: { [weak self] revision in
                    self?.lastSynchronizedRevision = revision
                }
            )
        }

        private func apply(
            _ request: EditorTextUpdateRequest,
            to textView: LacTextView
        ) {
            let fullRange = NSRange(
                location: 0,
                length: textView.textStorage?.length ?? 0
            )
            isApplyingAutomatedEdit = true
            defer { isApplyingAutomatedEdit = false }
            guard textView.shouldChangeText(
                in: fullRange,
                replacementString: request.text
            ) else { return }

            request.wasHandled = true
            textView.textStorage?.replaceCharacters(
                in: fullRange,
                with: request.text
            )
            textView.didChangeText()
            textView.setSelectedRange(request.selectionRange)
            textView.scrollRangeToVisible(request.selectionRange)
            textView.undoManager?.setActionName(request.actionName)
        }

        private func extractSelection(for request: EditorTextExtractionRequest) {
            guard isActive,
                  let textView,
                  let text = textView.textStorage?.mutableString,
                  let candidate = TextCodecService.candidate(
                      in: text,
                      selection: textView.selectedRange(),
                      allowsTokenAtCaret: request.allowsTokenAtCaret,
                      maximumLength: request.allowsTokenAtCaret
                          ? TextCodecService.automaticDetectionLimit
                          : nil
                  ) else { return }
            request.result = EditorTextSelectionSnapshot(
                documentID: document.id,
                range: candidate.range,
                text: candidate.text,
                editorRevision: contentRevision,
                wasExplicitSelection: textView.selectedRange().length > 0
            )
        }

        private func apply(
            _ request: EditorRangeReplacementRequest,
            to textView: LacTextView
        ) {
            guard request.expectedEditorRevision == contentRevision else {
                request.failureMessage = "编辑内容已变化，请重新执行转换"
                return
            }
            guard let storage = textView.textStorage,
                  request.range.location != NSNotFound,
                  NSMaxRange(request.range) <= storage.length,
                  storage.mutableString.substring(with: request.range)
                    == request.originalText else {
                request.failureMessage = "原文位置已变化，请重新执行转换"
                return
            }
            guard request.originalText != request.replacementText else {
                request.failureMessage = "转换结果与原文相同"
                return
            }

            isApplyingAutomatedEdit = true
            defer { isApplyingAutomatedEdit = false }
            guard textView.shouldChangeText(
                in: request.range,
                replacementString: request.replacementText
            ) else {
                request.failureMessage = "当前文本无法修改"
                return
            }
            request.wasHandled = true
            storage.replaceCharacters(
                in: request.range,
                with: request.replacementText
            )
            textView.didChangeText()
            let replacementRange = NSRange(
                location: request.range.location,
                length: (request.replacementText as NSString).length
            )
            textView.setSelectedRange(replacementRange)
            textView.scrollRangeToVisible(replacementRange)
            textView.undoManager?.setActionName(request.actionName)
        }

        func updateLayout(wordWrap: Bool, force: Bool = false) {
            guard isActive || force else {
                self.wordWrap = wordWrap
                return
            }
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

        func updatePerformanceFeatures() {
            foldLayoutManager?.allowsNonContiguousLayout = document.isLargeFileMode
            foldLayoutManager?.backgroundLayoutEnabled = !document.isLargeFileMode
            let nextSyntaxEnabled = document.isSyntaxHighlightingEnabled
            if syntaxHighlightingEnabled && !nextSyntaxEnabled {
                clearsDisabledSyntaxOnScroll = true
                cancelPendingHighlight()
                clearSyntaxAttributesInVisibleRange()
            } else if nextSyntaxEnabled {
                clearsDisabledSyntaxOnScroll = false
            }
            syntaxHighlightingEnabled = nextSyntaxEnabled
            if !document.isFoldingEnabled { clearFold() }
        }

        private func scheduleRulerRefreshAfterResize() {
            rulerResizeRefreshWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, let ruler else { return }
                rulerResizeRefreshWorkItem = nil
                ruler.invalidateHashMarks()
                ruler.setNeedsDisplay(ruler.bounds)
            }
            rulerResizeRefreshWorkItem = workItem
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

        private func scheduleDirectionalLayoutPrefetch() {
            layoutPrefetchWorkItem?.cancel()
            guard document.isLargeFileMode, !wordWrap,
                  let textView else { return }
            let currentY = textView.visibleRect.minY
            let direction: CGFloat = currentY >= lastViewportOriginY ? 1 : -1
            lastViewportOriginY = currentY
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView,
                      let layoutManager = textView.layoutManager,
                      let textContainer = textView.textContainer,
                      document.isLargeFileMode,
                      !wordWrap else { return }
                layoutPrefetchWorkItem = nil
                let visible = textView.visibleRect.offsetBy(
                    dx: -textView.textContainerOrigin.x,
                    dy: -textView.textContainerOrigin.y
                )
                let target = visible.offsetBy(
                    dx: 0,
                    dy: direction * visible.height
                )
                layoutManager.ensureLayout(
                    forBoundingRect: target,
                    in: textContainer
                )
            }
            layoutPrefetchWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
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

        func updateTopInset(_ topInset: CGFloat) {
            guard let textView,
                  abs(textView.textContainerInset.height - topInset) > 0.5 else {
                return
            }
            textView.textContainerInset = NSSize(width: 0, height: topInset)
            textView.needsDisplay = true
            refreshRuler()
        }

        func updateActivity(_ newValue: Bool) {
            guard isActive != newValue else { return }
            isActive = newValue
            guard newValue else {
                textCodecSuggestionWorkItem?.cancel()
                document.textCodecSuggestionTitle = nil
                cancelDelimiterMatch(clearHighlight: true, releaseSnapshot: true)
                textView?.requestsFirstResponderWhenAttached = false
                if let textView,
                   let window = textView.window,
                   window.firstResponder === textView {
                    window.makeFirstResponder(nil)
                }
                cancelPendingHighlight()
                return
            }
            textView?.requestsFirstResponderWhenAttached = true
            updateLayout(wordWrap: wordWrap, force: true)
            scheduleHighlight(delay: 0)
            scheduleDelimiterMatch(delay: 0)
            scheduleTextCodecSuggestion(delay: 0.18)
            DispatchQueue.main.async { [weak self] in
                guard let self, isActive, let textView, let window = textView.window else {
                    return
                }
                window.makeFirstResponder(textView)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalUpdate, let textView else { return }
            if let text = textView.textStorage?.mutableString,
               lineIndex.textLength != text.length {
                lineIndex.reset(with: text)
            }
            restorePendingOffscreenEdit(in: textView)
            document.noteLiveEdit(isEmpty: textView.textStorage?.length == 0)
            NotificationCenter.default.post(
                name: EditorCommandNotification.documentContentDidChange,
                object: document.id
            )
            document.statusMessage = nil
            clearFold()
            refreshRuler()
            updateCursor()
            scheduleDelimiterMatch()
            scheduleSelectionVisibilitySync()
            scheduleModelSync()
            scheduleHighlight()
            scheduleTextCodecSuggestion()
            if let location = pendingListNormalizationLocation {
                pendingListNormalizationLocation = nil
                scheduleOrderedListNormalization(around: location)
            }
        }

        private func scheduleModelSync() {
            modelSyncWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                modelSyncWorkItem = nil
                flushModelText(reconcileDirtyState: true)
            }
            modelSyncWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.35,
                execute: workItem
            )
        }

        func flushModelText(reconcileDirtyState: Bool) {
            if reconcileDirtyState {
                modelSyncWorkItem?.cancel()
                modelSyncWorkItem = nil
            }
            let needsSynchronization = document.hasPendingLiveEdits
            let syncSignpostID = OSSignpostID(log: editorPerformanceLog)
            if needsSynchronization {
                os_signpost(
                    .begin,
                    log: editorPerformanceLog,
                    name: "EditorModelSync",
                    signpostID: syncSignpostID
                )
            }
            if document.synchronizeLiveText() {
                lastSynchronizedRevision = document.textRevision
            }
            if needsSynchronization {
                os_signpost(
                    .end,
                    log: editorPerformanceLog,
                    name: "EditorModelSync",
                    signpostID: syncSignpostID
                )
            }
            if reconcileDirtyState {
                document.refreshDirtyState()
                lastSynchronizedRevision = document.textRevision
            }
        }

        func advanceContentRevision() {
            contentRevision &+= 1
            delimiterSnapshot = nil
            delimiterSnapshotRevision = nil
            delimiterMatchingContext.reset()
            cancelDelimiterMatch(clearHighlight: true)
        }

        private func scheduleSelectionVisibilitySync() {
            selectionVisibilityWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, let textView else { return }
                let selection = textView.selectedRange()
                guard let text = textView.textStorage?.mutableString else { return }
                if text.length > 0, let layoutManager = textView.layoutManager {
                    let anchor = min(selection.location, text.length - 1)
                    let lineRange = text.lineRange(
                        for: NSRange(location: anchor, length: 0)
                    )
                    layoutManager.invalidateLayout(
                        forCharacterRange: lineRange,
                        actualCharacterRange: nil
                    )
                    layoutManager.ensureLayout(forCharacterRange: lineRange)
                }
                textView.scrollRangeToVisible(selection)
                updateCursor()
                refreshRuler()
            }
            selectionVisibilityWorkItem = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func captureOffscreenSelectionPosition(
            in textView: NSTextView,
            affectedRange: NSRange,
            replacement: String
        ) {
            let expectedSelection = NSRange(
                location: affectedRange.location + (replacement as NSString).length,
                length: 0
            )
            if let pendingAnchor = pendingOffscreenEditAnchor {
                if pendingAnchor == affectedRange.location {
                    pendingOffscreenSelectionRange = expectedSelection
                    return
                }
                pendingSelectionScrollOriginY = nil
                pendingOffscreenEditAnchor = nil
                pendingOffscreenSelectionRange = nil
            }

            guard let layoutManager = textView.layoutManager,
                  let text = textView.textStorage?.mutableString else { return }
            // IME commits can temporarily move selectedRange to the document end.
            // The delegate's affected range remains the authoritative edit anchor.
            let location = min(affectedRange.location, text.length)
            if location == 0, textView.visibleRect.minY > 0.5 {
                pendingSelectionScrollOriginY = 0
                pendingOffscreenEditAnchor = affectedRange.location
                pendingOffscreenSelectionRange = expectedSelection
                return
            }
            let lineRect: NSRect
            if location == text.length,
               !layoutManager.extraLineFragmentRect.isEmpty {
                lineRect = layoutManager.extraLineFragmentRect
            } else if text.length > 0 {
                let anchor = min(location, text.length - 1)
                let lineRange = text.lineRange(
                    for: NSRange(location: anchor, length: 0)
                )
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: lineRange,
                    actualCharacterRange: nil
                )
                guard glyphRange.length > 0 else { return }
                lineRect = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphRange.location,
                    effectiveRange: nil
                )
            } else {
                lineRect = NSRect(
                    x: 0,
                    y: 0,
                    width: 1,
                    height: textView.font?.pointSize ?? 14
                )
            }

            var textViewRect = lineRect
            textViewRect.origin.y += textView.textContainerOrigin.y
            let visibleRect = textView.visibleRect
            guard textViewRect.maxY < visibleRect.minY
                    || textViewRect.minY > visibleRect.maxY else { return }
            pendingSelectionScrollOriginY = max(
                0,
                textViewRect.minY - textView.textContainerInset.height
            )
            pendingOffscreenEditAnchor = affectedRange.location
            pendingOffscreenSelectionRange = expectedSelection
        }

        private func restorePendingOffscreenEdit(in textView: NSTextView) {
            guard !textView.hasMarkedText(),
                  let expectedSelection = pendingOffscreenSelectionRange else {
                return
            }

            let textLength = textView.textStorage?.length ?? 0
            let location = min(expectedSelection.location, textLength)
            let selection = NSRange(
                location: location,
                length: min(
                    expectedSelection.length,
                    textLength - location
                )
            )
            isRestoringOffscreenEdit = true
            textView.setSelectedRange(selection)
            if let targetY = pendingSelectionScrollOriginY, let scrollView {
                scrollView.contentView.scroll(to: NSPoint(
                    x: scrollView.contentView.bounds.origin.x,
                    y: max(0, targetY)
                ))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            isRestoringOffscreenEdit = false
            pendingSelectionScrollOriginY = nil
            pendingOffscreenEditAnchor = nil
            pendingOffscreenSelectionRange = nil
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            clearFold()
            let replacement = replacementString ?? ""
            guard let nsText = textView.textStorage?.mutableString else { return false }
            let safeLocation = min(affectedCharRange.location, nsText.length)
            let safeRange = NSRange(
                location: safeLocation,
                length: min(
                    affectedCharRange.length,
                    nsText.length - safeLocation
                )
            )
            contentRevision &+= 1
            syntaxHighlightContext.invalidate(after: safeRange.location)
            delimiterMatchingContext.invalidate(after: safeRange.location)
            delimiterSnapshot = nil
            delimiterSnapshotRevision = nil
            cancelDelimiterMatch(clearHighlight: true)
            if !isApplyingAutomatedEdit {
                listNormalizationWorkItem?.cancel()
                listNormalizationQueue.cancelAllOperations()
                document.taskCoordinator.cancel(.listNormalization)
            }

            if !isApplyingAutomatedEdit {
                captureOffscreenSelectionPosition(
                    in: textView,
                    affectedRange: safeRange,
                    replacement: replacement
                )
            }

            if isApplyingAutomatedEdit {
                lineIndex.applyEdit(
                    range: safeRange,
                    replacement: replacement,
                    in: nsText
                )
                return true
            }
            guard document.language == .markdown else {
                lineIndex.applyEdit(
                    range: safeRange,
                    replacement: replacement,
                    in: nsText
                )
                return true
            }

            guard ListContinuationService.shouldNormalizeOrderedListEdit(
                    in: nsText,
                    range: safeRange,
                    replacement: replacement
                  ),
                  !ListContinuationService.isManualOrderedMarkerEdit(
                    in: nsText,
                    range: safeRange,
                    replacement: replacement
                  ) else {
                lineIndex.applyEdit(
                    range: safeRange,
                    replacement: replacement,
                    in: nsText
                )
                return true
            }

            let intendedCaretLocation = safeRange.location
                + (replacement as NSString).length
            if ListContinuationService.orderedListExceedsBackgroundThreshold(
                in: nsText,
                aroundUTF16Location: safeRange.location
            ) {
                pendingListNormalizationLocation = intendedCaretLocation
                lineIndex.applyEdit(
                    range: safeRange,
                    replacement: replacement,
                    in: nsText
                )
                return true
            }

            let prospectiveText = NSMutableString(string: textView.string)
            prospectiveText.replaceCharacters(in: safeRange, with: replacement)
            guard let normalization = ListContinuationService.normalizeOrderedList(
                in: prospectiveText as String,
                aroundUTF16Location: intendedCaretLocation
            ), let combinedEdit = combinedEdit(
                from: textView.string,
                to: normalization.text
            ) else {
                lineIndex.applyEdit(
                    range: safeRange,
                    replacement: replacement,
                    in: nsText
                )
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

        private func scheduleOrderedListNormalization(around location: Int) {
            listNormalizationWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, let textView else { return }
                listNormalizationWorkItem = nil
                let snapshot = textView.string
                let revision = contentRevision
                let taskGeneration = document.taskCoordinator.begin(.listNormalization)
                let operation = BlockOperation()
                operation.addExecutionBlock { [weak self, weak operation] in
                    guard let self, let operation, !operation.isCancelled else { return }
                    let result = ListContinuationService.normalizeOrderedList(
                        in: snapshot,
                        aroundUTF16Location: location
                    )
                    guard let result, !operation.isCancelled,
                          document.taskCoordinator.isCurrent(
                            taskGeneration,
                            for: .listNormalization
                          ) else { return }
                    DispatchQueue.main.async { [weak self, weak operation] in
                        guard let self, let operation, !operation.isCancelled,
                              revision == contentRevision,
                              document.taskCoordinator.isCurrent(
                                taskGeneration,
                                for: .listNormalization
                              ),
                              let edit = combinedEdit(from: snapshot, to: result.text) else { return }
                        document.taskCoordinator.finish(
                            .listNormalization,
                            generation: taskGeneration
                        )
                        let selectionBeforeApply = textView.selectedRange()
                        isApplyingAutomatedEdit = true
                        textView.insertText(
                            edit.replacement,
                            replacementRange: edit.range
                        )
                        textView.setSelectedRange(NSRange(
                            location: result.mappedLocation(
                                for: selectionBeforeApply.location
                            ),
                            length: 0
                        ))
                        textView.undoManager?.setActionName("整理有序列表")
                        isApplyingAutomatedEdit = false
                    }
                }
                document.taskCoordinator.attach(
                    operation,
                    kind: .listNormalization,
                    generation: taskGeneration
                )
                listNormalizationQueue.addOperation(operation)
            }
            listNormalizationWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingExternalUpdate,
                  !isRestoringOffscreenEdit else { return }
            guard textView?.hasMarkedText() != true else {
                cancelDelimiterMatch(clearHighlight: true)
                return
            }
            textView?.needsDisplay = true
            invalidateEntireRuler(displayImmediately: true)
            updateCursor()
            scheduleDelimiterMatch()
            scheduleTextCodecSuggestion()
        }

        func selectionDidChangeDuringTracking() {
            guard !isRestoringOffscreenEdit else { return }
            guard textView?.hasMarkedText() != true else {
                cancelDelimiterMatch(clearHighlight: true)
                return
            }
            textView?.needsDisplay = true
            invalidateEntireRuler(displayImmediately: true)
            scheduleDelimiterMatch()
            scheduleTextCodecSuggestion()
        }

        func synchronizeSelectionState() {
            DispatchQueue.main.async { [weak self] in
                self?.updateCursor()
                self?.scheduleDelimiterMatch(delay: 0)
                self?.scheduleTextCodecSuggestion(delay: 0.18)
            }
        }

        private func scheduleTextCodecSuggestion(delay: TimeInterval = 0.18) {
            textCodecSuggestionWorkItem?.cancel()
            guard isActive,
                  let textView,
                  !textView.hasMarkedText(),
                  textView.textStorage != nil else {
                document.textCodecSuggestionTitle = nil
                return
            }
            let selection = textView.selectedRange()
            let revision = contentRevision
            document.textCodecSuggestionTitle = nil
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, isActive,
                      let textView,
                      let currentText = textView.textStorage?.mutableString,
                      textView.selectedRange() == selection,
                      contentRevision == revision,
                      let candidate = TextCodecService.candidate(
                          in: currentText,
                          selection: selection,
                          allowsTokenAtCaret: true,
                          maximumLength: TextCodecService.automaticDetectionLimit
                      ),
                      let detection = TextCodecService.detect(
                          in: candidate.text,
                          allowsBase64: selection.length > 0
                      ) else {
                    return
                }
                document.textCodecSuggestionTitle = detection.suggestionTitle
            }
            textCodecSuggestionWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        func scheduleDelimiterMatch(delay: TimeInterval = 0.03) {
            cancelDelimiterMatch(clearHighlight: true)
            guard isActive,
                  DelimiterMatchingService.supports(currentLanguage),
                  let textView,
                  !textView.hasMarkedText() else { return }
            let selection = textView.selectedRange()
            guard selection.length <= 1 else { return }

            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      isActive,
                      !textView.hasMarkedText(),
                      textView.selectedRange() == selection else { return }
                delimiterMatchWorkItem = nil
                let revision = contentRevision
                let language = currentLanguage
                let snapshot: String
                if delimiterSnapshotRevision == revision,
                   let cached = delimiterSnapshot {
                    snapshot = cached
                } else {
                    snapshot = textView.string
                    delimiterSnapshot = snapshot
                    delimiterSnapshotRevision = revision
                }
                let taskGeneration = document.taskCoordinator.begin(.delimiterMatch)
                let operation = BlockOperation()
                operation.addExecutionBlock { [weak self, weak operation] in
                    guard let self, let operation, !operation.isCancelled else { return }
                    let match = DelimiterMatchingService.match(
                        in: snapshot,
                        selection: selection,
                        language: language,
                        revision: revision,
                        context: delimiterMatchingContext,
                        isCancelled: { operation.isCancelled }
                    )
                    guard !operation.isCancelled else { return }
                    DispatchQueue.main.async { [weak self, weak operation] in
                        guard let self, let operation, !operation.isCancelled,
                              isActive,
                              contentRevision == revision,
                              currentLanguage == language,
                              textView.selectedRange() == selection,
                              document.taskCoordinator.isCurrent(
                                taskGeneration,
                                for: .delimiterMatch
                              ) else { return }
                        document.taskCoordinator.finish(
                            .delimiterMatch,
                            generation: taskGeneration
                        )
                        delimiterMatchOperation = nil
                        if let match {
                            applyDelimiterMatch(match)
                        }
                    }
                }
                delimiterMatchOperation = operation
                document.taskCoordinator.attach(
                    operation,
                    kind: .delimiterMatch,
                    generation: taskGeneration
                )
                delimiterMatchQueue.addOperation(operation)
            }
            delimiterMatchWorkItem = workItem
            if delay <= 0 {
                DispatchQueue.main.async(execute: workItem)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            }
        }

        private func applyDelimiterMatch(_ match: DelimiterMatchingService.Match) {
            guard let layoutManager = textView?.layoutManager else { return }
            clearDelimiterHighlight()
            delimiterHighlightRanges = [match.openingRange, match.closingRange]
            for range in delimiterHighlightRanges {
                layoutManager.addTemporaryAttribute(
                    .backgroundColor,
                    value: NSColor.lacDelimiterMatchBackground,
                    forCharacterRange: range
                )
            }
        }

        private func clearDelimiterHighlight() {
            guard !delimiterHighlightRanges.isEmpty else { return }
            if let layoutManager = textView?.layoutManager {
                for range in delimiterHighlightRanges {
                    layoutManager.removeTemporaryAttribute(
                        .backgroundColor,
                        forCharacterRange: range
                    )
                }
            }
            delimiterHighlightRanges.removeAll(keepingCapacity: true)
        }

        private func cancelDelimiterMatch(
            clearHighlight: Bool,
            releaseSnapshot: Bool = false
        ) {
            delimiterMatchWorkItem?.cancel()
            delimiterMatchWorkItem = nil
            delimiterMatchOperation?.cancel()
            delimiterMatchOperation = nil
            delimiterMatchQueue.cancelAllOperations()
            document.taskCoordinator.cancel(.delimiterMatch)
            if clearHighlight { clearDelimiterHighlight() }
            if releaseSnapshot {
                delimiterSnapshot = nil
                delimiterSnapshotRevision = nil
            }
        }

        func scheduleHighlight(delay: TimeInterval = 0.12) {
            guard isActive, document.isSyntaxHighlightingEnabled else {
                cancelPendingHighlight()
                if clearsDisabledSyntaxOnScroll {
                    clearSyntaxAttributesInVisibleRange()
                }
                return
            }
            highlightWorkItem?.cancel()
            highlightGeneration &+= 1
            let generation = highlightGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      generation == highlightGeneration else { return }
                beginHighlight(generation: generation)
            }
            highlightWorkItem = work
            if delay <= 0 {
                DispatchQueue.main.async(execute: work)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }

        private func beginHighlight(generation: UInt) {
            guard isActive,
                  generation == highlightGeneration,
                  let textView,
                  !textView.hasMarkedText(),
                  let storage = textView.textStorage else { return }
            highlightWorkItem = nil

            flushModelText(reconcileDirtyState: false)
            let revision = contentRevision
            let language = currentLanguage
            let fontSize = currentFontSize
            let fullRange = NSRange(location: 0, length: storage.length)
            let targetRange = storage.length > 500_000
                ? visibleHighlightRange() ?? fullRange
                : fullRange
            if highlightedRevision == revision,
               highlightedLanguage == language,
               highlightedFontSize == fontSize,
               let highlightedRange,
               NSLocationInRange(targetRange.location, highlightedRange),
               NSMaxRange(targetRange) <= NSMaxRange(highlightedRange) {
                return
            }

            let synchronizedSnapshot = document.text
            let snapshot = (synchronizedSnapshot as NSString).length == storage.length
                ? synchronizedSnapshot
                : storage.string
            highlightOperation?.cancel()
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self, weak operation] in
                guard let operation, !operation.isCancelled else { return }
                let tokenizeSignpostID = OSSignpostID(log: editorPerformanceLog)
                os_signpost(
                    .begin,
                    log: editorPerformanceLog,
                    name: "SyntaxTokenize",
                    signpostID: tokenizeSignpostID
                )
                let tokens = SyntaxHighlighter.tokens(
                    in: snapshot,
                    language: language,
                    range: targetRange,
                    context: self?.syntaxHighlightContext,
                    revision: revision,
                    isCancelled: { operation.isCancelled }
                )
                os_signpost(
                    .end,
                    log: editorPerformanceLog,
                    name: "SyntaxTokenize",
                    signpostID: tokenizeSignpostID
                )
                guard !operation.isCancelled else { return }
                DispatchQueue.main.async { [weak self, weak operation] in
                    guard let operation, !operation.isCancelled else { return }
                    self?.applyHighlight(
                        tokens: tokens,
                        range: targetRange,
                        revision: revision,
                        language: language,
                        fontSize: fontSize,
                        generation: generation
                    )
                }
            }
            highlightOperation = operation
            highlightQueue.addOperation(operation)
        }

        private func applyHighlight(
            tokens: [SyntaxHighlighter.Token],
            range: NSRange,
            revision: UInt,
            language: EditorLanguage,
            fontSize: CGFloat,
            generation: UInt
        ) {
            guard isActive,
                  generation == highlightGeneration,
                  revision == contentRevision,
                  language == currentLanguage,
                  fontSize == currentFontSize,
                  let textView,
                  !textView.hasMarkedText(),
                  let storage = textView.textStorage,
                  NSMaxRange(range) <= storage.length else { return }
            let applySignpostID = OSSignpostID(log: editorPerformanceLog)
            os_signpost(
                .begin,
                log: editorPerformanceLog,
                name: "SyntaxApply",
                signpostID: applySignpostID
            )
            SyntaxHighlighter.apply(
                tokens: tokens,
                to: storage,
                baseFont: NSFont.monospacedSystemFont(
                    ofSize: fontSize,
                    weight: .regular
                ),
                range: range
            )
            os_signpost(
                .end,
                log: editorPerformanceLog,
                name: "SyntaxApply",
                signpostID: applySignpostID
            )
            highlightedRevision = revision
            highlightedLanguage = language
            highlightedFontSize = fontSize
            highlightedRange = range
            highlightOperation = nil
            refreshRuler()
        }

        private func cancelPendingHighlight() {
            highlightWorkItem?.cancel()
            highlightWorkItem = nil
            highlightOperation?.cancel()
            highlightOperation = nil
            highlightGeneration &+= 1
        }

        private func clearSyntaxAttributesInVisibleRange() {
            guard let storage = textView?.textStorage, storage.length > 0 else { return }
            let range = storage.length > 500_000
                ? visibleHighlightRange() ?? NSRange(location: 0, length: 0)
                : NSRange(location: 0, length: storage.length)
            guard range.length > 0 else { return }
            SyntaxHighlighter.apply(
                tokens: [],
                to: storage,
                baseFont: NSFont.monospacedSystemFont(
                    ofSize: currentFontSize,
                    weight: .regular
                ),
                range: range
            )
        }

        private func updateCursor() {
            guard let textView,
                  let text = textView.textStorage?.mutableString else { return }
            let selection = textView.selectedRange()
            document.selectionRange = selection
            let location = min(selection.location, text.length)
            let position = lineIndex.position(
                at: location,
                in: text
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
            scheduleRulerRefresh(ensureLayout: true)
        }

        private func refreshRulerForViewportChange() {
            scheduleRulerRefresh(ensureLayout: false)
        }

        private func scheduleRulerRefresh(ensureLayout: Bool) {
            rulerRefreshNeedsLayout = rulerRefreshNeedsLayout || ensureLayout
            guard rulerRefreshWorkItem == nil else { return }
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                rulerRefreshWorkItem = nil
                if rulerRefreshNeedsLayout {
                    rulerRefreshNeedsLayout = false
                    ensureVisibleLayout()
                }
                invalidateEntireRuler()
            }
            rulerRefreshWorkItem = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func invalidateEntireRuler(displayImmediately: Bool = false) {
            guard let ruler else { return }
            ruler.invalidateHashMarks()
            ruler.needsDisplay = true
            ruler.setNeedsDisplay(ruler.bounds)
            if displayImmediately {
                ruler.displaySelectionImmediately()
            }
        }

        func resetLineIndex(with text: String) {
            lineIndex.reset(with: text)
        }

        func resetSyntaxHighlightContext() {
            syntaxHighlightContext.reset()
            delimiterMatchingContext.reset()
            delimiterSnapshot = nil
            delimiterSnapshotRevision = nil
            cancelDelimiterMatch(clearHighlight: true)
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
            let layoutSignpostID = OSSignpostID(log: editorPerformanceLog)
            os_signpost(
                .begin,
                log: editorPerformanceLog,
                name: "TextKitVisibleLayout",
                signpostID: layoutSignpostID
            )
            layoutManager.ensureLayout(
                forBoundingRect: visibleRect,
                in: textContainer
            )
            os_signpost(
                .end,
                log: editorPerformanceLog,
                name: "TextKitVisibleLayout",
                signpostID: layoutSignpostID
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
            let padding = 16_000
            let start = max(0, characterRange.location - padding)
            let end = min(
                textView.textStorage?.length ?? 0,
                NSMaxRange(characterRange) + padding
            )
            return NSRange(location: start, length: max(0, end - start))
        }

        private func toggleFold() {
            guard document.isFoldingEnabled,
                  let textView, textView.window?.firstResponder === textView,
                  let foldLayoutManager else { return }
            if foldLayoutManager.foldedRange != nil {
                clearFold()
            } else if let range = FoldService.foldableRange(
                in: textView.string,
                at: textView.selectedRange().location,
                language: document.language
            ) {
                foldLayoutManager.setFoldedRange(range)
            }
            refreshFoldLayout()
        }

        func clearFold() {
            guard foldLayoutManager?.foldedRange != nil else { return }
            foldLayoutManager?.setFoldedRange(nil)
            refreshFoldLayout()
        }

        private func clearFoldIfNeeded(toReveal range: NSRange) {
            guard let foldedRange = foldLayoutManager?.foldedRange,
                  NSIntersectionRange(foldedRange, range).length > 0 else { return }
            clearFold()
        }

        private func refreshFoldLayout() {
            guard let textView else { return }
            if let textContainer = textView.textContainer {
                foldLayoutManager?.ensureLayout(for: textContainer)
            }
            textView.needsLayout = true
            textView.needsDisplay = true
            ruler?.invalidateHashMarks()
            ruler?.needsDisplay = true
        }
    }
}

final class EditorSessionStore: ObservableObject {
    private final class Entry {
        let coordinator: EditorTextView.Coordinator
        var scrollView: NSScrollView?
        var accessOrder: UInt

        init(
            coordinator: EditorTextView.Coordinator,
            accessOrder: UInt
        ) {
            self.coordinator = coordinator
            self.accessOrder = accessOrder
        }
    }

    private let limit: Int
    private let inactiveMemoryBudget: Int
    private let maximumCacheableSessionCost: Int
    private var entries: [UUID: Entry] = [:]
    private var accessOrder: UInt = 0
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(
        limit: Int,
        inactiveMemoryBudget: Int,
        maximumCacheableSessionCost: Int
    ) {
        self.limit = max(1, limit)
        self.inactiveMemoryBudget = max(0, inactiveMemoryBudget)
        self.maximumCacheableSessionCost = max(0, maximumCacheableSessionCost)
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            handleMemoryPressure(source.data)
        }
        source.resume()
        memoryPressureSource = source
    }

    convenience init(limit: Int) {
        self.init(
            limit: limit,
            inactiveMemoryBudget: 64 * 1_024 * 1_024,
            maximumCacheableSessionCost: 24 * 1_024 * 1_024
        )
    }

    deinit {
        memoryPressureSource?.cancel()
    }

    func coordinator(for document: EditorDocument) -> EditorTextView.Coordinator {
        if let entry = entries[document.id] {
            touch(entry)
            return entry.coordinator
        }
        let coordinator = EditorTextView.Coordinator(document: document)
        accessOrder &+= 1
        entries[document.id] = Entry(
            coordinator: coordinator,
            accessOrder: accessOrder
        )
        trimIfNeeded()
        return coordinator
    }

    func cachedView(for documentID: UUID) -> NSScrollView? {
        guard let entry = entries[documentID],
              let scrollView = entry.scrollView else { return nil }
        touch(entry)
        scrollView.removeFromSuperview()
        return scrollView
    }

    func store(
        _ scrollView: NSScrollView,
        coordinator: EditorTextView.Coordinator,
        for documentID: UUID
    ) {
        let entry: Entry
        if let existing = entries[documentID] {
            entry = existing
        } else {
            accessOrder &+= 1
            entry = Entry(coordinator: coordinator, accessOrder: accessOrder)
            entries[documentID] = entry
        }
        entry.scrollView = scrollView
        touch(entry)
        trimIfNeeded()
    }

    func retainDocuments(_ documentIDs: Set<UUID>) {
        entries = entries.filter { documentIDs.contains($0.key) }
    }

    private func touch(_ entry: Entry) {
        accessOrder &+= 1
        entry.accessOrder = accessOrder
    }

    private func trimIfNeeded() {
        while inactiveEntries.count > limit
                || inactiveMemoryCost > inactiveMemoryBudget
                || inactiveEntries.contains(where: {
                    $0.value.coordinator.estimatedMemoryCost > maximumCacheableSessionCost
                }) {
            let oversized = inactiveEntries
                .filter { $0.value.coordinator.estimatedMemoryCost > maximumCacheableSessionCost }
                .min { $0.value.accessOrder < $1.value.accessOrder }
            guard let victim = oversized ?? inactiveEntries.min(by: {
                $0.value.accessOrder < $1.value.accessOrder
            }) else { break }
            evict(victim.key)
        }
    }

    private var inactiveEntries: [(key: UUID, value: Entry)] {
        entries.filter { !$0.value.coordinator.isSessionActive }
    }

    private var inactiveMemoryCost: Int {
        inactiveEntries.reduce(0) { $0 + $1.value.coordinator.estimatedMemoryCost }
    }

    private func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        let inactive = inactiveEntries.sorted {
            $0.value.accessOrder < $1.value.accessOrder
        }
        if event.contains(.critical) {
            inactive.forEach { evict($0.key) }
        } else if event.contains(.warning) {
            inactive.filter {
                $0.value.coordinator.estimatedMemoryCost > maximumCacheableSessionCost / 2
            }.forEach { evict($0.key) }
        }
    }

    private func evict(_ documentID: UUID) {
        guard let entry = entries[documentID], !entry.coordinator.isSessionActive else { return }
        entry.coordinator.prepareForEviction()
        entry.coordinator.document.taskCoordinator.cancel(.search)
        entry.coordinator.document.taskCoordinator.cancel(.replace)
        entry.coordinator.document.taskCoordinator.cancel(.json)
        entry.coordinator.document.taskCoordinator.cancel(.preview)
        entry.coordinator.document.taskCoordinator.cancel(.delimiterMatch)
        os_signpost(
            .event,
            log: editorPerformanceLog,
            name: "MemoryEviction"
        )
        entries.removeValue(forKey: documentID)
    }
}
