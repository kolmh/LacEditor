import AppKit
import os
import SwiftUI

let editorPerformanceLog = OSLog(
    subsystem: "com.laceditor.LacEditor",
    category: "EditorPerformance"
)

struct EditorTextView: NSViewRepresentable {
    @ObservedObject var document: EditorDocument
    let sessionStore: EditorSessionStore
    let fontSize: CGFloat
    let lineSpacing: CGFloat
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
        layoutManager.editorLineSpacing = lineSpacing
        EditorLayoutPolicy.configure(
            layoutManager,
            textLength: (document.text as NSString).length
        )
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
        let lineSpacingChanged = context.coordinator.foldLayoutManager?
            .editorLineSpacing != lineSpacing
        let languageChanged = context.coordinator.currentLanguage != document.language
        if documentChanged || languageChanged {
            context.coordinator.resetSyntaxHighlightContext()
        }
        context.coordinator.document = document
        context.coordinator.currentFontSize = fontSize
        context.coordinator.currentLanguage = document.language
        context.coordinator.foldLayoutManager?.editorLineSpacing = lineSpacing
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

        context.coordinator.updateLayout(
            wordWrap: wordWrap,
            force: lineSpacingChanged
        )
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

}
