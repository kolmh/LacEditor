import AppKit
import Combine
import SwiftUI

@MainActor
final class WindowManager: ObservableObject {
    static let tabPasteboardType = NSPasteboard.PasteboardType(
        "com.laceditor.editor-tab"
    )

    let recentFiles = RecentFilesStore()
    @Published private(set) var activeState: AppState?
    @Published private(set) var draggedDocumentID: UUID?
    private(set) var terminationApproved = false

    private final class ActiveTabDrag {
        let documentID: UUID
        weak var sourceState: AppState?
        weak var targetState: AppState?
        var targetDocumentID: UUID?
        var wasAccepted = false

        init(documentID: UUID, sourceState: AppState) {
            self.documentID = documentID
            self.sourceState = sourceState
        }
    }

    private var states: [UUID: AppState] = [:]
    private var windowControllers: [UUID: NSWindowController] = [:]
    private var transferringDocumentIDs: Set<UUID> = []
    private var activeTabDrag: ActiveTabDrag?
    private var isConfirmingRecentFilesClear = false
    private var activeStateCancellable: AnyCancellable?
    private var recentFilesCancellable: AnyCancellable?
    private lazy var appearanceMenuController = AppearanceMenuController(
        windowManager: self
    )

    init() {
        recentFilesCancellable = recentFiles.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        _ = appearanceMenuController
    }

    func register(windowID: UUID, state: AppState, window: NSWindow) {
        states[windowID] = state
        state.hostWindow = window
        if window.isKeyWindow || activeState == nil {
            activate(windowID: windowID)
        }
    }

    func activate(windowID: UUID) {
        guard let state = states[windowID] else { return }
        activeState = state
        activeStateCancellable = state.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    func unregister(windowID: UUID) {
        let removedState = states.removeValue(forKey: windowID)
        windowControllers.removeValue(forKey: windowID)
        if activeState === removedState {
            activeState = states.values.first
        }
    }

    @discardableResult
    func openNewWindow(
        with document: EditorDocument? = nil,
        near screenPoint: NSPoint? = nil
    ) -> AppState {
        let windowID = UUID()
        let state = AppState(initialDocument: document, recentFiles: recentFiles)
        states[windowID] = state

        let rootView = EditorWindowRoot(
            appState: state,
            windowManager: self,
            windowID: windowID
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView
        ]
        window.title = state.windowTitle
        window.titleVisibility = .visible
        window.toolbarStyle = .unifiedCompact
        window.setContentSize(NSSize(width: 1120, height: 720))
        window.minSize = NSSize(width: 900, height: 560)
        if let screenPoint {
            position(window, near: screenPoint)
        } else {
            window.center()
        }
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        windowControllers[windowID] = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        return state
    }

    func openFileInNewWindow(_ url: URL) {
        openNewWindow().openFile(url)
    }

    func requestClearRecentFiles() {
        guard !recentFiles.urls.isEmpty,
              !isConfirmingRecentFilesClear else {
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清除最近文件？"
        alert.informativeText = """
        这只会清空最近文件列表，不会删除磁盘上的任何文件。此操作无法撤销。
        """
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        isConfirmingRecentFilesClear = true

        if let window = activeState?.hostWindow {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                isConfirmingRecentFilesClear = false
                if response == .alertFirstButtonReturn {
                    recentFiles.clear()
                }
            }
        } else {
            let response = alert.runModal()
            isConfirmingRecentFilesClear = false
            if response == .alertFirstButtonReturn {
                recentFiles.clear()
            }
        }
    }

    func beginTabDrag(_ document: EditorDocument, from state: AppState) {
        guard state.documents.contains(where: { $0.id == document.id }) else {
            return
        }
        activeTabDrag = ActiveTabDrag(
            documentID: document.id,
            sourceState: state
        )
        draggedDocumentID = document.id
        state.selectedDocumentID = document.id
    }

    func setTabDragTarget(
        in targetState: AppState,
        before targetDocumentID: UUID?
    ) {
        guard let drag = activeTabDrag else { return }
        drag.targetState = targetState
        drag.targetDocumentID = targetDocumentID
    }

    func clearTabDragTarget(
        in targetState: AppState,
        before targetDocumentID: UUID?
    ) {
        guard let drag = activeTabDrag,
              drag.targetState === targetState,
              drag.targetDocumentID == targetDocumentID else {
            return
        }
        drag.targetState = nil
        drag.targetDocumentID = nil
    }

    @discardableResult
    func acceptTabDrag(
        into targetState: AppState,
        before targetDocumentID: UUID?
    ) -> Bool {
        guard let drag = activeTabDrag,
              let sourceState = drag.sourceState else {
            return false
        }

        let accepted = moveDraggedDocument(
            drag.documentID,
            from: sourceState,
            to: targetState,
            before: targetDocumentID
        )
        drag.wasAccepted = accepted
        return accepted
    }

    func finishTabDrag(at screenPoint: NSPoint) {
        guard let drag = activeTabDrag else {
            draggedDocumentID = nil
            return
        }
        activeTabDrag = nil
        draggedDocumentID = nil
        guard let sourceState = drag.sourceState else { return }
        if !drag.wasAccepted, let targetState = drag.targetState,
           moveDraggedDocument(
               drag.documentID,
               from: sourceState,
               to: targetState,
               before: drag.targetDocumentID
           ) {
            return
        }
        guard !drag.wasAccepted,
              let document = sourceState.documents.first(where: {
                  $0.id == drag.documentID
              }) else {
            return
        }

        if let targetState = editorState(at: screenPoint) {
            guard targetState !== sourceState else { return }
            _ = transferDocument(
                document.id,
                from: sourceState,
                to: targetState,
                before: nil
            )
        } else {
            detach(document, from: sourceState, near: screenPoint)
        }
    }

    func cancelTabDrag() {
        activeTabDrag = nil
        draggedDocumentID = nil
    }

    func detach(
        _ document: EditorDocument,
        from state: AppState,
        near screenPoint: NSPoint? = nil
    ) {
        guard transferringDocumentIDs.insert(document.id).inserted else { return }

        DispatchQueue.main.async { [weak self, weak state] in
            guard let self else { return }
            defer { transferringDocumentIDs.remove(document.id) }
            guard let state,
                  let transferred = state.takeDocumentForTransfer(document) else {
                return
            }
            openNewWindow(with: transferred, near: screenPoint)
        }
    }

    func confirmClosingAllWindows() -> Bool {
        terminationApproved = false
        for state in states.values where !state.confirmClosingAllDocuments() {
            return false
        }
        terminationApproved = true
        return true
    }

    private func transferDocument(
        _ documentID: UUID,
        from sourceState: AppState,
        to targetState: AppState,
        before targetDocumentID: UUID?
    ) -> Bool {
        guard sourceState !== targetState,
              let document = sourceState.documents.first(where: {
                  $0.id == documentID
              }),
              let transferred = sourceState.takeDocumentForTransfer(document)
        else {
            return false
        }
        targetState.receiveTransferredDocument(
            transferred,
            before: targetDocumentID
        )
        targetState.hostWindow?.makeKeyAndOrderFront(nil)
        return true
    }

    private func moveDraggedDocument(
        _ documentID: UUID,
        from sourceState: AppState,
        to targetState: AppState,
        before targetDocumentID: UUID?
    ) -> Bool {
        if sourceState === targetState {
            sourceState.moveDocument(
                documentID,
                before: targetDocumentID
            )
            return true
        }
        return transferDocument(
            documentID,
            from: sourceState,
            to: targetState,
            before: targetDocumentID
        )
    }

    private func editorState(at screenPoint: NSPoint) -> AppState? {
        for window in NSApp.orderedWindows
        where window.isVisible && window.frame.contains(screenPoint) {
            if let state = states.values.first(where: {
                $0.hostWindow === window
            }) {
                return state
            }
        }
        return nil
    }

    private func position(_ window: NSWindow, near screenPoint: NSPoint) {
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(screenPoint)
        }) ?? NSScreen.main else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let desired = NSPoint(
            x: screenPoint.x - min(150, size.width * 0.2),
            y: screenPoint.y - size.height + 28
        )
        window.setFrameOrigin(NSPoint(
            x: min(max(desired.x, visible.minX), visible.maxX - size.width),
            y: min(max(desired.y, visible.minY), visible.maxY - size.height)
        ))
    }
}
