import AppKit
import Combine
import SwiftUI

@MainActor
final class WindowManager: ObservableObject {
    static let tabPasteboardType = NSPasteboard.PasteboardType(
        "com.laceditor.editor-tab"
    )

    let recentFiles = RecentFilesStore()
    let sidebarLibrary = SidebarLibraryStore()
    let preferences: AppPreferences
    let recoveryStore: DocumentRecoveryStore?
    let workspaceStore: WorkspaceSessionStore?
    @Published private(set) var activeState: AppState?
    @Published private(set) var draggedDocumentID: UUID?
    /// Changes whenever the retained primary scene is reopened. Sidebar
    /// scroll views use this identity to discard stale content offsets from a
    /// window that was closed after its last tab was removed.
    @Published private(set) var primaryReopenGeneration = 0
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
    // SwiftUI's primary Window scene can be closed and later reopened from
    // the Dock without recreating its AppState. Keep that state registered so
    // commands and sidebar bindings become active again when the scene returns.
    private var primaryWindowID: UUID?
    private var transferringDocumentIDs: Set<UUID> = []
    private var activeTabDrag: ActiveTabDrag?
    private var isConfirmingRecentFilesClear = false
    private var activeStateCancellable: AnyCancellable?
    private var recentFilesCancellable: AnyCancellable?
    private var sidebarLibraryCancellable: AnyCancellable?
    private let fileService = FileService()
    private var recoveredDocuments: [EditorDocument] = []
    private struct RestoredWindow {
        let documents: [EditorDocument]
        let selectedDocumentID: UUID?
        let isSidebarVisible: Bool
        let frame: WorkspaceWindowFrame?
    }
    private var initialRestoredWindow: RestoredWindow?
    private var pendingRestoredWindows: [RestoredWindow] = []
    private var pendingFinderURLs: [URL] = []
    private var didApplyInitialRestoration = false
    private lazy var appearanceMenuController = AppearanceMenuController(
        windowManager: self
    )
    private lazy var menuLocalizationController = MenuLocalizationController()

    init(
        recoveryStore: DocumentRecoveryStore? = nil,
        workspaceStore: WorkspaceSessionStore? = nil,
        preferences: AppPreferences? = nil
    ) {
        self.recoveryStore = recoveryStore
        self.workspaceStore = workspaceStore
        self.preferences = preferences ?? AppPreferences()
        let recoverySnapshots = (try? recoveryStore?.startSession()) ?? []
        restoreInitialSession(
            workspace: try? workspaceStore?.loadAndConsume(),
            recoverySnapshots: recoverySnapshots
        )
        recentFilesCancellable = recentFiles.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        sidebarLibraryCancellable = sidebarLibrary.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        _ = appearanceMenuController
        _ = menuLocalizationController
    }

    func takeRecoveredDocuments() -> [EditorDocument] {
        defer { recoveredDocuments.removeAll() }
        return recoveredDocuments
    }

    func persistRecoverySnapshotsImmediately() {
        states.values.forEach { $0.persistRecoverySnapshotsImmediately() }
    }

    func register(windowID: UUID, state: AppState, window: NSWindow) {
        let wasDetachedPrimaryWindow = windowID == primaryWindowID
            && state.hostWindow !== window
            && (state.hostWindow == nil || state.hostWindow?.isVisible == false)
        if primaryWindowID == nil {
            primaryWindowID = windowID
        }
        states[windowID] = state
        state.windowManager = self
        state.hostWindow = window
        if wasDetachedPrimaryWindow {
            primaryReopenGeneration &+= 1
        }
        if window.isKeyWindow || activeState == nil {
            activate(windowID: windowID)
        }
        if !didApplyInitialRestoration,
           let restoration = initialRestoredWindow {
            didApplyInitialRestoration = true
            apply(restoration, to: state, window: window)
            let additionalWindows = pendingRestoredWindows
            pendingRestoredWindows.removeAll()
            DispatchQueue.main.async { [weak self] in
                additionalWindows.forEach { self?.openRestoredWindow($0) }
                self?.drainPendingFinderURLs()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.drainPendingFinderURLs()
            }
        }
    }

    /// Routes files opened from Finder into the already registered editor
    /// window. Finder can send this event while SwiftUI is still constructing
    /// the primary scene, so retain the URLs until registration completes
    /// instead of creating a temporary second window.
    func openFilesFromFinder(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        guard activeState != nil else {
            pendingFinderURLs.append(contentsOf: files)
            return
        }
        files.forEach { openFile($0, preferredState: activeState) }
    }

    private func drainPendingFinderURLs() {
        guard activeState != nil, !pendingFinderURLs.isEmpty else { return }
        let files = pendingFinderURLs
        pendingFinderURLs.removeAll()
        files.forEach { openFile($0, preferredState: activeState) }
    }

    func activate(windowID: UUID) {
        guard let state = states[windowID] else { return }
        activeState = state
        activeStateCancellable = state.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    func unregister(windowID: UUID) {
        guard let state = states[windowID] else { return }
        state.closeAuxiliaryWindows()

        // The primary SwiftUI scene is reusable after its last tab closes.
        // Removing it here leaves the reopened window with visible content but
        // no active AppState, which disables Command+T/Command+W and blanks the
        // sidebar. Secondary native windows still leave the manager normally.
        if windowID == primaryWindowID {
            // SwiftUI commonly reuses this NSWindow when the app is reopened
            // from the Dock. Keep the weak reference so the reopen handler can
            // bring the existing workspace back instead of losing its route.
            activeState = states.values.first(where: {
                $0 !== state && $0.hostWindow?.isVisible == true
            }) ?? state
            return
        }

        let removedState = states.removeValue(forKey: windowID)
        windowControllers.removeValue(forKey: windowID)
        if activeState === removedState {
            activeState = states.values.first(where: {
                $0.hostWindow?.isVisible == true
            })
        }
    }

    /// Re-show the retained primary SwiftUI scene after the last editor
    /// window was closed and the application was reopened from the Dock.
    func reopenPrimaryWindow() {
        guard let primaryWindowID,
              let state = states[primaryWindowID],
              let window = state.hostWindow else { return }
        primaryReopenGeneration &+= 1
        register(windowID: primaryWindowID, state: state, window: window)
        activate(windowID: primaryWindowID)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    func openNewWindow(
        with document: EditorDocument? = nil,
        near screenPoint: NSPoint? = nil
    ) -> AppState {
        let windowID = UUID()
        let state = AppState(
            initialDocument: document,
            recentFiles: recentFiles,
            preferences: preferences,
            recoveryStore: recoveryStore
        )
        state.windowManager = self
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
        configureEditorWindowChrome(window)
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
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            configureEditorWindowChrome(window)
        }
        return state
    }

    private func openRestoredWindow(_ restoration: RestoredWindow) {
        let windowID = UUID()
        let state = AppState(
            initialDocuments: restoration.documents,
            recentFiles: recentFiles,
            preferences: preferences,
            recoveryStore: recoveryStore
        )
        state.windowManager = self
        state.selectedDocumentID = resolvedSelectedDocumentID(for: restoration)
        state.isSidebarVisible = restoration.isSidebarVisible
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
        configureEditorWindowChrome(window)
        window.minSize = NSSize(width: 900, height: 560)
        applyFrame(restoration.frame, to: window)
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        windowControllers[windowID] = controller
        controller.showWindow(nil)
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            configureEditorWindowChrome(window)
        }
    }

    func openFileInNewWindow(_ url: URL) {
        openFile(url, preferredState: nil, createWindowIfNeeded: true)
    }

    func openFile(
        _ url: URL,
        preferredState: AppState?,
        createWindowIfNeeded: Bool = false
    ) {
        let identity = DocumentFileIdentity.resolve(url)
        if let match = openDocument(matching: identity) {
            focus(match.document, in: match.state)
            return
        }
        let target = createWindowIfNeeded ? openNewWindow() : (preferredState ?? activeState ?? openNewWindow())
        target.beginOpeningFile(url)
    }

    func conflictingDocument(
        at url: URL,
        excluding documentID: UUID
    ) -> (state: AppState, document: EditorDocument)? {
        let identity = DocumentFileIdentity.resolve(url)
        return states.values.lazy.compactMap { state in
            state.documents.first(where: {
                $0.id != documentID && $0.fileIdentity?.matches(identity) == true
            }).map { (state, $0) }
        }.first
    }

    func focus(_ document: EditorDocument, in state: AppState) {
        state.selectedDocumentID = document.id
        state.hostWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openDocument(
        matching identity: DocumentFileIdentity
    ) -> (state: AppState, document: EditorDocument)? {
        states.values.lazy.compactMap { state in
            state.documents.first(where: {
                $0.fileIdentity?.matches(identity) == true
            }).map { (state, $0) }
        }.first
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

    func requestCreateSidebarGroup(adding url: URL? = nil) {
        presentTextPrompt(
            title: "新建分组",
            message: "输入分组名称。",
            initialValue: "新分组",
            actionTitle: "创建"
        ) { [weak self] name in
            guard let self,
                  let id = sidebarLibrary.createGroup(named: name) else { return }
            if let url { sidebarLibrary.add(url, toGroup: id) }
        }
    }

    func requestRenameSidebarGroup(_ group: SidebarFileGroup) {
        presentTextPrompt(
            title: "重命名分组",
            message: "输入新的分组名称。",
            initialValue: group.name,
            actionTitle: "重命名"
        ) { [weak self] name in
            self?.sidebarLibrary.renameGroup(group.id, to: name)
        }
    }

    func requestDeleteSidebarGroup(_ group: SidebarFileGroup) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除分组“\(group.name)”？"
        alert.informativeText = "只会删除侧边栏中的快捷入口，不会删除磁盘上的文件。"
        alert.addButton(withTitle: "删除分组")
        alert.addButton(withTitle: "取消")
        present(alert) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.sidebarLibrary.deleteGroup(group.id)
            }
        }
    }

    func requestRelocateSidebarFile(_ missingURL: URL) {
        let panel = NSOpenPanel()
        panel.title = "重新定位“\(missingURL.lastPathComponent)”"
        panel.message = "选择该文件当前所在的位置。"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = FileService.supportedContentTypes
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let replacement = panel.url else { return }
            self?.sidebarLibrary.replace(missingURL, with: replacement)
            self?.recentFiles.replace(missingURL, with: replacement)
        }
        if let window = activeState?.hostWindow {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(panel.runModal())
        }
    }

    private func presentTextPrompt(
        title: String,
        message: String,
        initialValue: String,
        actionTitle: String,
        completion: @escaping (String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initialValue
        alert.accessoryView = field
        present(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            completion(field.stringValue)
        }
    }

    private func present(
        _ alert: NSAlert,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = activeState?.hostWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    func requestRenameFile(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "重命名文件"
        alert.informativeText = "请输入新的文件名。"
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")

        let nameField = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 320, height: 24)
        )
        nameField.stringValue = url.lastPathComponent
        nameField.selectText(nil)
        alert.accessoryView = nameField

        let rename: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let newName = nameField.stringValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            self?.renameFile(url, to: newName)
        }

        if let window = activeState?.hostWindow {
            alert.beginSheetModal(for: window, completionHandler: rename)
        } else {
            rename(alert.runModal())
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

    private func renameFile(_ url: URL, to newName: String) {
        do {
            let newURL = try fileService.rename(url, to: newName)
            for state in states.values {
                state.updateRenamedFileReference(from: url, to: newURL)
            }
            recentFiles.replace(url, with: newURL)
            sidebarLibrary.replace(url, with: newURL)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "无法重命名文件"
            if let window = activeState?.hostWindow {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
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

    func confirmClosingAllWindows(completion: @escaping (Bool) -> Void) {
        terminationApproved = false
        confirmClosingStates(Array(states.values), completion: completion)
    }

    func requestApplicationTermination(
        completion: @escaping (Bool) -> Void
    ) {
        switch preferences.workspaceExitBehavior {
        case .askToSave:
            confirmClosingAllWindows(completion: completion)
        case .preserveWorkspace:
            if hasDirtyDocuments,
               !preferences.hasConfirmedWorkspaceExitPrompt {
                presentFirstWorkspaceExitPrompt(completion: completion)
            } else {
                preserveWorkspaceAndTerminate(completion: completion)
            }
        }
    }

    private func confirmClosingStates(
        _ queue: [AppState],
        completion: @escaping (Bool) -> Void
    ) {
        guard let state = queue.first else {
            terminationApproved = true
            guard let workspaceStore else {
                finishCleanRecovery(completion: completion)
                return
            }
            workspaceStore.clear { [weak self] in
                guard let self, let recoveryStore else {
                    completion(true)
                    return
                }
                recoveryStore.finishCleanly {
                    completion(true)
                }
            }
            return
        }
        state.confirmClosingAllDocuments { [weak self] approved in
            guard let self, approved else {
                completion(false)
                return
            }
            self.confirmClosingStates(Array(queue.dropFirst()), completion: completion)
        }
    }

    var hasPendingSaves: Bool {
        states.values.contains(where: \.hasPendingSave)
    }

    func finishTerminationAfterPendingSaves(
        completion: @escaping (Bool) -> Void
    ) {
        waitForPendingSaves { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            confirmClosingAllWindows(completion: completion)
        }
    }

    private func waitForPendingSaves(completion: @escaping () -> Void) {
        guard hasPendingSaves else {
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitForPendingSaves(completion: completion)
        }
    }

    private var hasDirtyDocuments: Bool {
        states.values.contains { state in
            state.documents.contains { $0.isDirty || $0.hasPendingLiveEdits }
        }
    }

    private func presentFirstWorkspaceExitPrompt(
        completion: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "退出并保留当前工作区？"
        alert.informativeText = """
        所有窗口、标签和未保存内容会在下次启动时恢复。磁盘文件不会被自动修改。
        """
        alert.addButton(withTitle: "保留并退出")
        alert.addButton(withTitle: "检查未保存文件")
        alert.addButton(withTitle: "取消")
        present(alert) { [weak self] response in
            guard let self else {
                completion(false)
                return
            }
            switch response {
            case .alertFirstButtonReturn:
                preferences.confirmWorkspaceExitPrompt()
                preserveWorkspaceAndTerminate(completion: completion)
            case .alertSecondButtonReturn:
                confirmClosingAllWindows(completion: completion)
            default:
                completion(false)
            }
        }
    }

    private func preserveWorkspaceAndTerminate(
        completion: @escaping (Bool) -> Void
    ) {
        terminationApproved = false
        waitForPendingSaves { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            let snapshot = captureWorkspaceSnapshot()
            guard let workspaceStore else {
                confirmClosingAllWindows(completion: completion)
                return
            }
            workspaceStore.save(snapshot) { [weak self] result in
                guard let self else {
                    completion(false)
                    return
                }
                switch result {
                case .success:
                    terminationApproved = true
                    guard let recoveryStore else {
                        completion(true)
                        return
                    }
                    recoveryStore.finishCleanly {
                        completion(true)
                    }
                case let .failure(error):
                    presentWorkspaceSaveError(error)
                    completion(false)
                }
            }
        }
    }

    private func captureWorkspaceSnapshot() -> WorkspaceSessionSnapshot {
        let orderedStates = NSApp.orderedWindows.compactMap { window in
            states.values.first(where: { $0.hostWindow === window })
        }
        let remainingStates = states.values.filter { state in
            !orderedStates.contains(where: { $0 === state })
        }
        let windows = (orderedStates + remainingStates).map { state in
            let documents = state.documents.map { document in
                WorkspaceDocumentSnapshot(
                    documentID: document.id,
                    text: document.synchronizedText(),
                    sourceURL: document.url,
                    language: document.language,
                    encoding: document.fileEncoding,
                    isDirty: document.isDirty,
                    selectionRange: document.selectionRange,
                    scrollPositionRatio: document.scrollPositionRatio,
                    isPreviewVisible: document.isPreviewVisible,
                    fileRevisionSnapshot: document.fileRevisionSnapshot
                )
            }
            let frame = state.hostWindow.map {
                WorkspaceWindowFrame(
                    x: Double($0.frame.origin.x),
                    y: Double($0.frame.origin.y),
                    width: Double($0.frame.width),
                    height: Double($0.frame.height)
                )
            }
            return WorkspaceWindowSnapshot(
                documents: documents,
                selectedDocumentID: state.selectedDocumentID,
                isSidebarVisible: state.isSidebarVisible,
                frame: frame
            )
        }
        return WorkspaceSessionSnapshot(windows: windows)
    }

    private func presentWorkspaceSaveError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.alertStyle = .critical
        alert.messageText = "无法保留工作区"
        alert.informativeText = "工作区没有完整写入，LacEditor 已取消退出。\n\n\(error.localizedDescription)"
        if let window = activeState?.hostWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func finishCleanRecovery(completion: @escaping (Bool) -> Void) {
        guard let recoveryStore else {
            completion(true)
            return
        }
        recoveryStore.finishCleanly { completion(true) }
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

    private func restoreInitialSession(
        workspace: WorkspaceSessionSnapshot?,
        recoverySnapshots: [DocumentRecoverySnapshot]
    ) {
        var recoveryByID = Dictionary(
            uniqueKeysWithValues: recoverySnapshots.map { ($0.documentID, $0) }
        )
        if let workspace, !workspace.windows.isEmpty {
            let restored = workspace.windows.map { window in
                let documents = window.documents.map { snapshot in
                    if let recovery = recoveryByID.removeValue(
                        forKey: snapshot.documentID
                    ) {
                        return Self.makeRecoveredDocument(from: recovery)
                    }
                    return Self.makeWorkspaceDocument(from: snapshot)
                }
                return RestoredWindow(
                    documents: documents,
                    selectedDocumentID: window.selectedDocumentID,
                    isSidebarVisible: window.isSidebarVisible,
                    frame: window.frame
                )
            }
            var windows = restored
            if !recoveryByID.isEmpty {
                let extras = recoveryByID.values
                    .sorted { $0.capturedAt < $1.capturedAt }
                    .map(Self.makeRecoveredDocument)
                if windows.isEmpty {
                    windows = [RestoredWindow(
                        documents: extras,
                        selectedDocumentID: extras.first?.id,
                        isSidebarVisible: true,
                        frame: nil
                    )]
                } else {
                    let first = windows[0]
                    windows[0] = RestoredWindow(
                        documents: first.documents + extras,
                        selectedDocumentID: first.selectedDocumentID,
                        isSidebarVisible: first.isSidebarVisible,
                        frame: first.frame
                    )
                }
            }
            initialRestoredWindow = windows.first
            pendingRestoredWindows = Array(windows.dropFirst())
            recoveredDocuments = windows.first?.documents ?? []
            return
        }
        recoveredDocuments = recoverySnapshots.map(Self.makeRecoveredDocument)
    }

    private func apply(
        _ restoration: RestoredWindow,
        to state: AppState,
        window: NSWindow
    ) {
        state.selectedDocumentID = resolvedSelectedDocumentID(for: restoration)
        state.isSidebarVisible = restoration.isSidebarVisible
        applyFrame(restoration.frame, to: window)
    }

    private func resolvedSelectedDocumentID(
        for restoration: RestoredWindow
    ) -> UUID? {
        if let selectedDocumentID = restoration.selectedDocumentID,
           restoration.documents.contains(where: {
               $0.id == selectedDocumentID
           }) {
            return selectedDocumentID
        }
        return restoration.documents.first?.id
    }

    private func applyFrame(
        _ storedFrame: WorkspaceWindowFrame?,
        to window: NSWindow
    ) {
        guard let storedFrame else {
            window.setContentSize(NSSize(width: 1120, height: 720))
            window.center()
            return
        }
        var frame = NSRect(
            x: storedFrame.x,
            y: storedFrame.y,
            width: max(900, storedFrame.width),
            height: max(560, storedFrame.height)
        )
        let screen = NSScreen.screens.first(where: {
            $0.visibleFrame.intersects(frame)
        }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true)
    }

    private static func makeWorkspaceDocument(
        from snapshot: WorkspaceDocumentSnapshot
    ) -> EditorDocument {
        let document = EditorDocument(
            id: snapshot.documentID,
            text: snapshot.text,
            url: snapshot.sourceURL,
            language: snapshot.language,
            fileEncoding: snapshot.encoding,
            fileRevisionSnapshot: snapshot.fileRevisionSnapshot,
            isDirty: snapshot.isDirty,
            requiresExplicitSave: snapshot.isDirty
        )
        document.selectionRange = snapshot.selectionRange
        document.scrollPositionRatio = snapshot.scrollPositionRatio
        document.isPreviewVisible = snapshot.language == .markdown
            && snapshot.isPreviewVisible
            && document.performanceProfile == .standard
        if snapshot.isDirty {
            document.statusMessage = "已恢复上次工作区，尚未保存"
        }
        return document
    }

    private static func makeRecoveredDocument(
        from snapshot: DocumentRecoverySnapshot
    ) -> EditorDocument {
        let document = EditorDocument(
            id: snapshot.documentID,
            text: snapshot.text,
            url: snapshot.sourceURL,
            language: snapshot.language,
            fileEncoding: snapshot.encoding,
            fileRevisionSnapshot: snapshot.fileRevisionSnapshot,
            isDirty: true,
            requiresExplicitSave: true
        )
        document.selectionRange = snapshot.selectionRange
        document.scrollPositionRatio = snapshot.scrollPositionRatio
        document.isPreviewVisible = snapshot.language == .markdown
            && snapshot.isPreviewVisible
            && document.performanceProfile == .standard
        document.statusMessage = "已从上次异常退出中恢复，请确认后保存"
        return document
    }
}
