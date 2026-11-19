import AppKit
import Combine
import XCTest
@testable import LacEditor

@MainActor
final class InteractionPolishTests: XCTestCase {
    func testUnsavedSidebarChangesRequireExplicitExitDecision() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LacEditorSidebarExit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("blocked")
        try Data("blocked".utf8).write(to: blocker)
        let library = SidebarLibraryStore(storageURL: blocker.appendingPathComponent("Sidebar.json"))
        library.toggleFavorite(root.appendingPathComponent("draft.txt"))
        let suite = "LacEditorTests.sidebar.exit.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.workspaceExitBehavior = .askToSave
        let manager = WindowManager(preferences: preferences, recentFiles: RecentFilesStore(defaults: defaults),
                                    sidebarLibrary: library)
        let state = manager.openNewWindow()
        let window = try XCTUnwrap(state.hostWindow)
        defer { state.closeAuxiliaryWindows(); window.delegate = nil; window.close() }
        for choice in ["取消退出", "仍然退出"] {
            var approved: Bool?
            manager.requestApplicationTermination { approved = $0 }
            try await Task.sleep(for: .milliseconds(80))
            let sheet = try XCTUnwrap(window.attachedSheet)
            func button(in view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.title == choice { return button }
                return view.subviews.lazy.compactMap { button(in: $0) }.first
            }
            try XCTUnwrap(button(in: try XCTUnwrap(sheet.contentView))).performClick(nil)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(approved, choice == "仍然退出")
            XCTAssertNotNil(library.persistenceError)
        }
    }

    func testSidebarSaveFailureHasNoSuccessFeedbackAndCanRetryWithoutLosingChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LacEditorSidebarFailure-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Store")
        let storage = folder.appendingPathComponent("Sidebar.json")
        let library = SidebarLibraryStore(storageURL: storage)
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        library.toggleFavorite(first)
        let saved = try Data(contentsOf: storage)
        let backup = root.appendingPathComponent("ExistingStore")
        try FileManager.default.moveItem(at: folder, to: backup)
        try Data("blocked parent".utf8).write(to: folder)

        let suite = "LacEditorTests.sidebar.failure.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = WindowManager(
            preferences: AppPreferences(defaults: defaults), recentFiles: RecentFilesStore(defaults: defaults),
            sidebarLibrary: library
        )
        let state = AppState(recentFiles: manager.recentFiles, preferences: manager.preferences)
        state.windowManager = manager
        defer { state.closeAuxiliaryWindows() }
        state.toggleSidebarFavorite(second)
        XCTAssertNotNil(library.persistenceError)
        XCTAssertNil(state.sidebarFeedback.item)
        XCTAssertTrue(library.isFavorite(first))
        XCTAssertTrue(library.isFavorite(second))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("Sidebar.json")), saved)
        XCTAssertFalse(library.retrySaving())

        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: backup, to: folder)
        XCTAssertTrue(library.retrySaving())
        XCTAssertNil(library.persistenceError)
        let reloaded = SidebarLibraryStore(storageURL: storage)
        XCTAssertTrue(reloaded.isFavorite(first))
        XCTAssertTrue(reloaded.isFavorite(second))
    }

    func testTextConversionRejectsModelAndPendingLiveChangesBeforeCompletion() async throws {
        for liveChange in [false, true] {
            let suite = "LacEditorTests.conversion.stale.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let document = EditorDocument(text: "before")
            let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults),
                                 preferences: AppPreferences(defaults: defaults))
            defer { state.closeAuxiliaryWindows() }
            let selection = EditorTextSelectionSnapshot(
                documentID: document.id, range: NSRange(location: 0, length: 6), text: "before",
                editorRevision: 400, wasExplicitSelection: true
            )
            let observer = NotificationCenter.default.addObserver(
                forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main
            ) { notification in
                (notification.object as? EditorTextExtractionRequest)?.result = selection
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            state.presentTextTransformation(.base64Encode)
            if liveChange { document.noteLiveEdit(isEmpty: false) }
            else { document.text = "after" }
            for _ in 0..<100 {
                if document.statusMessage != "正在转换文本…" { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(state.textTransformation.preview)
            XCTAssertEqual(document.statusMessage, "内容已变化，转换已取消")
        }
    }

    func testTextConversionAcceptsPendingLiveSelectionWithDifferentEditorRevision() async throws {
        let suite = "LacEditorTests.conversion.live.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "old")
        let providerID = UUID()
        document.attachLiveTextProvider(id: providerID, provider: { "new" }, acknowledgement: { _ in })
        document.noteLiveEdit(isEmpty: false)
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults),
                             preferences: AppPreferences(defaults: defaults))
        defer { state.closeAuxiliaryWindows(); document.detachLiveTextProvider(id: providerID) }
        let selection = EditorTextSelectionSnapshot(
            documentID: document.id, range: NSRange(location: 0, length: 3), text: "new",
            editorRevision: 400, wasExplicitSelection: true
        )
        let observer = NotificationCenter.default.addObserver(
            forName: EditorCommandNotification.extractTextSelection, object: nil, queue: .main
        ) { notification in
            (notification.object as? EditorTextExtractionRequest)?.result = selection
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        state.presentTextTransformation(.base64Encode)
        for _ in 0..<100 {
            if state.textTransformation.preview != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(document.text, "new")
        XCTAssertEqual(state.textTransformation.preview?.output, "bmV3")
        XCTAssertEqual(state.textTransformation.preview?.editorRevision, 400)
    }

    func testClosingWaitCanBeCancelledAndDoesNotBlockOtherDocuments() async throws {
        let suite = "LacEditorTests.close.wait.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saving = EditorDocument(text: "saving")
        let other = EditorDocument(text: "other")
        saving.markSaved()
        other.markSaved()
        let state = AppState(initialDocuments: [saving, other], recentFiles: RecentFilesStore(defaults: defaults),
                             preferences: AppPreferences(defaults: defaults))
        defer { state.closeAuxiliaryWindows() }
        saving.ioState = .saving
        state.close(saving)
        state.close(other)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(state.documents.map(\.id), [saving.id])
        state.close(saving) // Cancel the pending close without cancelling its save.
        saving.ioState = .idle
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(state.selectedDocument === saving)
        state.close(saving)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(state.documents.contains { $0 === saving })
    }

    func testTransferringDocumentInvalidatesItsPendingCloseRequest() async throws {
        let suite = "LacEditorTests.close.transfer.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "saved")
        document.markSaved()
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults),
                             preferences: AppPreferences(defaults: defaults))
        defer { state.closeAuxiliaryWindows() }
        document.ioState = .saving
        state.close(document)
        let transferred = try XCTUnwrap(state.takeDocumentForTransfer(document))
        state.receiveTransferredDocument(transferred, before: nil)
        document.ioState = .idle
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(state.documents.contains { $0 === document })
        state.close(document)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(state.documents.contains { $0 === document })
    }

    func testPreviewToolbarItemFollowsLanguageAndKeepsOtherControls() async throws {
        _ = NSApplication.shared
        let suite = "LacEditorTests.ui9.toolbar.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "# 正文", language: .plainText)
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults),
                             preferences: AppPreferences(defaults: defaults))
        defer { state.closeAuxiliaryWindows() }
        let controller = EditorWindowToolbarController(appState: state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let toolbar = controller.makeToolbar()
        window.toolbar = toolbar
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        controller.update()
        let preview = NSToolbarItem.Identifier("LacEditor.Preview")
        let stableItems = toolbar.items.map(\.itemIdentifier).filter { $0 != preview }
        XCTAssertFalse(stableItems.isEmpty, "AppKit must materialize the toolbar before checking it")
        XCTAssertTrue(try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == preview }).isHidden)
        let otherState = AppState(initialDocument: EditorDocument(text: "# 另一标签", language: .markdown),
                                  recentFiles: RecentFilesStore(defaults: defaults),
                                  preferences: AppPreferences(defaults: defaults))
        defer { otherState.closeAuxiliaryWindows() }
        let otherController = EditorWindowToolbarController(appState: otherState)
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                                   styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close() }
        let otherToolbar = otherController.makeToolbar()
        otherWindow.toolbar = otherToolbar
        otherWindow.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        otherController.update()
        for _ in 0..<3 {
            for language in EditorLanguage.allCases {
                document.language = language
                controller.update()
                XCTAssertEqual(toolbar.items.filter { $0.itemIdentifier == preview && !$0.isHidden }.count,
                               language == .markdown ? 1 : 0, "Wrong toolbar for \(language)")
                XCTAssertEqual(toolbar.items.map(\.itemIdentifier).filter { $0 != preview }, stableItems)
                XCTAssertFalse(try XCTUnwrap(otherToolbar.items.first { $0.itemIdentifier == preview }).isHidden,
                               "Another window's Markdown button must remain visible")
            }
        }
        document.language = .markdown
        controller.update()
        otherState.selectedDocument?.language = .json
        otherController.update()
        XCTAssertFalse(try XCTUnwrap(toolbar.items.first { $0.itemIdentifier == preview }).isHidden)
        XCTAssertTrue(try XCTUnwrap(otherToolbar.items.first { $0.itemIdentifier == preview }).isHidden)
        XCTAssertEqual(document.text, "# 正文")
        XCTAssertFalse(document.isDirty)
    }

    func testTooltipOwnershipScrollMenuResizeAndRelease() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 800))
        scroll.documentView = content
        window.contentView = scroll
        let first = ToolTipTrackingView(text: "文件一", shortcut: nil)
        first.frame = NSRect(x: 0, y: 0, width: 100, height: 40)
        content.addSubview(first)
        var second: ToolTipTrackingView? = ToolTipTrackingView(text: "文件二", shortcut: "⌘,")
        weak var released = second
        content.addSubview(try XCTUnwrap(second))
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        XCTAssertNil(first.toolTip, "Native and custom help must not appear together")
        first.mouseEntered(with: event)
        second?.mouseEntered(with: event)
        XCTAssertFalse(first.isPresentationPending, "A new owner must cancel a missing mouseExited")
        XCTAssertTrue(second?.isPresentationPending == true)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        XCTAssertFalse(second?.isPresentationPending == true)
        for name in [NSMenu.didBeginTrackingNotification, NSWindow.didResizeNotification] {
            first.mouseEntered(with: event)
            NotificationCenter.default.post(name: name, object: name == NSMenu.didBeginTrackingNotification ? NSMenu() : window)
            XCTAssertFalse(first.isPresentationPending)
        }
        second?.mouseEntered(with: event)
        second?.removeFromSuperview()
        second = nil
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(released, "Pending help and its event monitor must not retain a removed row")
        XCTAssertTrue(window.childWindows?.isEmpty ?? true, "Cancelled delayed work must not recreate help")
    }

    func testSidebarScrollbarEmphasisIsLocalAndTracksSystemPolicy() {
        let sidebar = NSScrollView(frame: NSRect(x: 0, y: 0, width: 250, height: 400))
        sidebar.hasVerticalScroller = true
        let editor = NSScrollView()
        editor.hasVerticalScroller = true
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 900))
        let bridge = NativeScrollViewConfigurator.ConfiguratorView()
        bridge.indicatorOpacity = 0.6
        content.addSubview(bridge)
        sidebar.documentView = content
        bridge.configureScrollViews()
        XCTAssertEqual(sidebar.verticalScroller?.alphaValue,
                       NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.6)
        XCTAssertEqual(editor.verticalScroller?.alphaValue, 1)
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        XCTAssertEqual(sidebar.scrollerStyle, NSScroller.preferredScrollerStyle)
        XCTAssertTrue(sidebar.autohidesScrollers)
        XCTAssertEqual(editor.verticalScroller?.alphaValue, 1)
    }

    func testFeedbackExpiryReplacementPauseUndoAndRelease() async throws {
        var state: InlineFeedbackState? = InlineFeedbackState(duration: .milliseconds(100))
        weak var released = state
        state?.show("旧消息")
        try await Task.sleep(for: .milliseconds(60))
        state?.show("新消息")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(state?.item?.title, "新消息", "Old expiry must not clear a newer result")
        state?.setInteracting(true)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(state?.item?.title, "新消息", "Pointer/key focus must keep the action available")
        var undoCount = 0
        state?.show("已移除") { undoCount += 1; return true }
        state?.undo()
        state?.undo()
        XCTAssertEqual(undoCount, 1)
        XCTAssertEqual(state?.item?.title, "已撤销上次操作")
        state?.setInteracting(false)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertNil(state?.item)
        state?.show("待清理")
        state = nil
        XCTAssertNil(released, "An expiry task must not retain the window-local state")
    }

    func testGuardedSidebarUndoPreservesOtherGroupsAndRejectsLaterEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("sidebar.json")
        let library = SidebarLibraryStore(storageURL: storage)
        let a = directory.appendingPathComponent("a.md")
        let b = directory.appendingPathComponent("b.md")
        let group = try XCTUnwrap(library.createGroup(named: "原分组"))
        let other = try XCTUnwrap(library.createGroup(named: "其他分组"))
        library.add(a, toGroup: group)
        library.add(b, toGroup: group)
        let before = library.groups[0].paths
        library.remove(a, fromGroup: group)
        let expected = library.groups[0].paths
        library.add(a, toGroup: other)
        library.setExpanded(false, for: group)
        XCTAssertTrue(library.restoreGroupFiles(before, in: group, ifUnchanged: expected))
        XCTAssertEqual(library.groups[0].paths, before)
        XCTAssertFalse(library.groups[0].isExpanded)
        XCTAssertEqual(library.groups[1].urls, [a])
        library.remove(a, fromGroup: group)
        library.add(a, toGroup: group)
        XCTAssertFalse(library.restoreGroupFiles(before, in: group, ifUnchanged: expected))
        library.toggleFavorite(a)
        let favorites = library.favoritePaths
        library.toggleFavorite(a)
        library.toggleFavorite(b)
        XCTAssertFalse(library.restoreFavorites(favorites, ifUnchanged: []))
        XCTAssertEqual(library.favoriteURLs, [b])
        XCTAssertEqual(SidebarLibraryStore(storageURL: storage).groups, library.groups)
    }

    func testRecentUndoDoesNotOverwriteLaterOpenedFiles() throws {
        let suite = "LacEditorTests.ui8.recent.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recent = RecentFilesStore(defaults: defaults)
        let a = URL(fileURLWithPath: "/tmp/a.md")
        let b = URL(fileURLWithPath: "/tmp/b.md")
        recent.record(a)
        let before = recent.urls
        recent.remove(a)
        XCTAssertTrue(recent.restore(before, ifUnchanged: []))
        recent.remove(a)
        recent.record(b)
        XCTAssertFalse(recent.restore(before, ifUnchanged: []))
        XCTAssertEqual(RecentFilesStore(defaults: defaults).urls, [b])
    }

    func testWindowLocalSidebarFeedbackUndoDoesNotTouchDocument() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "LacEditorTests.ui8.actions.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let library = SidebarLibraryStore(storageURL: directory.appendingPathComponent("sidebar.json"))
        let manager = WindowManager(preferences: AppPreferences(defaults: defaults),
                                    recentFiles: RecentFilesStore(defaults: defaults), sidebarLibrary: library)
        let document = EditorDocument(text: "保留正文", language: .plainText)
        let state = manager.openNewWindow(with: document)
        defer { state.closeAuxiliaryWindows(); state.hostWindow?.delegate = nil; state.hostWindow?.close() }
        let file = directory.appendingPathComponent("a.txt")
        state.toggleSidebarFavorite(file)
        XCTAssertTrue(library.isFavorite(file))
        XCTAssertTrue(state.sidebarFeedback.item?.canUndo == true)
        state.sidebarFeedback.undo()
        XCTAssertFalse(library.isFavorite(file))
        let group = try XCTUnwrap(library.createGroup(named: "测试组"))
        state.addSidebarFile(file, toGroup: group)
        state.sidebarFeedback.undo()
        XCTAssertTrue(library.groups[0].paths.isEmpty)
        state.addSidebarFile(file, toGroup: group)
        state.removeSidebarFile(file, fromGroup: group)
        state.sidebarFeedback.undo()
        XCTAssertEqual(library.groups[0].urls, [file])
        manager.recentFiles.record(file)
        state.removeRecentSidebarFile(file)
        manager.recentFiles.record(directory.appendingPathComponent("later.txt"))
        state.sidebarFeedback.undo()
        XCTAssertEqual(state.sidebarFeedback.item?.title, "列表已变化，未撤销")
        XCTAssertEqual(document.text, "保留正文")
        XCTAssertFalse(document.isDirty)
        state.closeAuxiliaryWindows()
        XCTAssertNil(state.sidebarFeedback.item)
    }

    func testDocumentChangesOnlyPublishMeaningfulChromeUpdates() throws {
        let suite = "LacEditorTests.ui8.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(text: "测试", language: .plainText)
        let state = AppState(initialDocument: document, recentFiles: RecentFilesStore(defaults: defaults),
                             preferences: AppPreferences(defaults: defaults))
        defer { state.closeAuxiliaryWindows() }
        document.isDirty = true
        var changes = 0
        let subscription = state.objectWillChange.sink { changes += 1 }
        for index in 1...100 {
            document.cursorColumn = index
            document.selectionRange = NSRange(location: index, length: 0)
            document.isDirty = true
        }
        print("UI8_REFRESH repeated_dirty_and_cursor_updates=100 app_state_notifications=\(changes)")
        if ProcessInfo.processInfo.environment["LACEDITOR_UI8_BASELINE"] != "1" {
            XCTAssertEqual(changes, 0)
            document.isDirty = false
            XCTAssertEqual(changes, 1, "The actual saved-state transition must still reach chrome")
            document.language = .markdown
            XCTAssertEqual(changes, 2)
        }
        withExtendedLifetime(subscription) {}
    }

    func testCopyFeedbackDoesNotOverwriteStalePreviewMessageOrUserPasteboard() throws {
        let suite = "LacEditorTests.ui8.copy.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(recentFiles: RecentFilesStore(defaults: defaults), preferences: AppPreferences(defaults: defaults))
        defer { state.closeAuxiliaryWindows() }
        let document = try XCTUnwrap(state.selectedDocument)
        state.textTransformation.present(TextTransformationPreview(
            documentID: document.id, range: NSRange(location: 0, length: 3), input: "%41", output: "A",
            editorRevision: 0, operation: .smartDecode, detectedKind: nil))
        state.textTransformation.invalidate(documentID: document.id)
        let staleMessage = state.textTransformation.message
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        state.copyTextTransformationResult(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "A")
        XCTAssertEqual(state.textTransformation.copyFeedback.item?.title, "结果已复制")
        XCTAssertEqual(state.textTransformation.message, staleMessage)
        XCTAssertFalse(state.textTransformation.canReplace)
        state.textTransformation.clear()
        XCTAssertNil(state.textTransformation.copyFeedback.item)
    }
}
