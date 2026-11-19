import AppKit
import XCTest
import WebKit
@testable import LacEditor

@MainActor
final class NativeTabsTests: XCTestCase {
    func testPreparedPrimaryDrainsEarlyFinderEventAndReopensSameSession() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cold-launch.txt")
        try "cold-launch text".write(to: url, atomically: true, encoding: .utf8)
        let manager = WindowManager()
        let state = AppState(recentFiles: manager.recentFiles, preferences: manager.preferences)
        let id = UUID()
        manager.preparePrimaryWindow(windowID: id, state: state)
        XCTAssertNil(state.hostWindow)
        manager.openFilesFromFinder([url])
        XCTAssertNil(state.hostWindow, "Early files wait until applicationDidFinishLaunching")
        manager.reopenPrimaryWindow()
        let window = try XCTUnwrap(state.hostWindow)
        defer {
            for member in window.tabGroup?.windows ?? [window] { member.delegate = nil; member.close() }
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(manager.activeState === state)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(state.selectedDocument?.url, url)
        XCTAssertEqual(state.selectedDocument?.text, "cold-launch text")
        manager.reopenPrimaryWindow()
        XCTAssertTrue(state.hostWindow === window)
        XCTAssertEqual(manager.captureWorkspaceSnapshot().windows.flatMap(\.documents).count, 1)
        state.closeSelectedDocument()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(state.selectedDocument?.isDisposableBlank == true)
        state.closeSelectedDocument()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(window.isVisible)
        manager.openFilesFromFinder([url])
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(state.hostWindow === window)
        XCTAssertEqual(state.selectedDocument?.text, "cold-launch text")
    }

    func testLastPopulatedTabBecomesBlankBeforeWindowCloses() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for choice in ["已保存", "不保存", "取消", "保存"] {
            let url = folder.appendingPathComponent("\(choice).txt")
            try "original".write(to: url, atomically: true, encoding: .utf8)
            let manager = WindowManager()
            let document = EditorDocument(text: "original", url: url)
            if choice != "已保存" { document.text = "edited"; document.refreshDirtyState() }
            let state = manager.openNewWindow(with: document)
            let window = try XCTUnwrap(state.hostWindow)
            defer { window.delegate = nil; window.close() }
            try await Task.sleep(for: .milliseconds(300))
            state.closeSelectedDocument()
            try await Task.sleep(for: .milliseconds(200))
            if choice != "已保存" {
                let sheet = try XCTUnwrap(window.attachedSheet)
                func button(in view: NSView) -> NSButton? {
                    if let button = view as? NSButton, button.title == choice { return button }
                    return view.subviews.lazy.compactMap { button(in: $0) }.first
                }
                try XCTUnwrap(button(in: try XCTUnwrap(sheet.contentView))).performClick(nil)
                try await Task.sleep(for: .milliseconds(500))
            }
            XCTAssertTrue(window.isVisible)
            XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), choice == "保存" ? "edited" : "original")
            if choice == "取消" {
                XCTAssertTrue(state.selectedDocument === document)
                XCTAssertTrue(document.isDirty)
            } else {
                XCTAssertTrue(state.selectedDocument?.isDisposableBlank == true)
                XCTAssertNotEqual(state.selectedDocumentID, document.id)
                state.closeSelectedDocument()
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertFalse(window.isVisible)
                manager.reopenPrimaryWindow()
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertTrue(window.isVisible)
                XCTAssertTrue(manager.activeState === state)
                XCTAssertTrue(state.selectedDocument?.isDisposableBlank == true)
            }
        }
    }

    func testNativeTabCloseSheetSaveDiscardAndCancel() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for choice in ["不保存", "取消", "保存"] {
            let url = folder.appendingPathComponent("\(choice).txt")
            try "original".write(to: url, atomically: true, encoding: .utf8)
            let manager = WindowManager()
            let parentState = manager.openNewWindow()
            let document = EditorDocument(text: "original", url: url)
            document.text = "edited"
            document.refreshDirtyState()
            let state = manager.openNewWindow(with: document)
            let parent = try XCTUnwrap(parentState.hostWindow)
            let window = try XCTUnwrap(state.hostWindow)
            defer {
                window.delegate = nil; window.close()
                parent.delegate = nil; parent.close()
            }
            parent.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(300))
            window.performClose(nil)
            try await Task.sleep(for: .milliseconds(250))
            let sheet = try XCTUnwrap(window.attachedSheet, "\(choice): missing confirmation")
            func button(in view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.title == choice { return button }
                return view.subviews.lazy.compactMap { button(in: $0) }.first
            }
            try XCTUnwrap(button(in: try XCTUnwrap(sheet.contentView))).performClick(nil)
            try await Task.sleep(for: .milliseconds(600))
            if choice == "取消" {
                XCTAssertTrue(window.isVisible)
                XCTAssertEqual(parent.tabGroup?.windows.count, 2)
                XCTAssertTrue(document.isDirty)
            } else {
                XCTAssertFalse(window.isVisible, "\(choice) must close the confirmed native tab")
                XCTAssertFalse(parent.tabGroup?.windows.contains(window) == true)
            }
            XCTAssertNil(window.attachedSheet, "Do not present a second confirmation")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), choice == "保存" ? "edited" : "original")
        }
    }

    func testNativeGroupRoundTripAndLegacyWorkspaceMigration() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WorkspaceSessionStore(rootURL: folder)
        let manager = WindowManager()
        let first = manager.openNewWindow(with: EditorDocument(text: "未保存的中文", isDirty: true, requiresExplicitSave: true))
        try await Task.sleep(for: .milliseconds(200))
        let second = manager.openNativeTab(from: first)
        second.selectedDocument?.text = "second draft"
        let firstWindow = try XCTUnwrap(first.hostWindow)
        let secondWindow = try XCTUnwrap(second.hostWindow)
        defer {
            firstWindow.delegate = nil; firstWindow.close()
            secondWindow.delegate = nil; secondWindow.close()
        }
        try await Task.sleep(for: .milliseconds(200))
        let captured = manager.captureWorkspaceSnapshot()
        XCTAssertEqual(captured.windows.count, 1)
        XCTAssertEqual(captured.windows.first?.documents.map(\.text), ["未保存的中文", "second draft"])
        XCTAssertEqual(captured.windows.first?.selectedDocumentID, second.selectedDocumentID)
        let saved = await withCheckedContinuation { continuation in
            store.save(captured) { continuation.resume(returning: $0) }
        }
        try saved.get()
        let restoredManager = WindowManager(workspaceStore: store)
        let recovered = restoredManager.takeRecoveredDocuments()
        let restored = AppState(initialDocuments: Array(recovered.prefix(1)), recentFiles: restoredManager.recentFiles, preferences: restoredManager.preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        configureEditorWindowChrome(window, appState: restored)
        restoredManager.register(windowID: UUID(), state: restored, window: window)
        defer {
            for member in window.tabGroup?.windows ?? [window] { member.delegate = nil; member.close() }
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(window.tabGroup?.windows.count, 2)
        let roundTrip = restoredManager.captureWorkspaceSnapshot()
        XCTAssertEqual(roundTrip.windows.count, 1)
        XCTAssertEqual(roundTrip.windows.first?.documents.map(\.text), captured.windows.first?.documents.map(\.text))
        XCTAssertEqual(roundTrip.windows.first?.selectedDocumentID, captured.windows.first?.selectedDocumentID)
        XCTAssertTrue(roundTrip.windows.first?.documents.allSatisfy(\.isDirty) == true)
    }

    func testFinderOpenPreservesExistingDraftAndDeduplicatesAcrossNativeTabs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("finder.txt")
        try "disk text".write(to: url, atomically: true, encoding: .utf8)
        let manager = WindowManager()
        let draft = manager.openNewWindow(with: EditorDocument(text: "keep me", isDirty: true))
        try await Task.sleep(for: .milliseconds(200))
        let window = try XCTUnwrap(draft.hostWindow)
        defer {
            for member in window.tabGroup?.windows ?? [window] { member.delegate = nil; member.close() }
        }
        manager.openFilesFromFinder([url])
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(draft.selectedDocument?.text, "keep me")
        XCTAssertEqual(window.tabGroup?.windows.count, 2)
        manager.openFilesFromFinder([url])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(window.tabGroup?.windows.count, 2)
        let snapshot = manager.captureWorkspaceSnapshot()
        XCTAssertEqual(snapshot.windows.first?.documents.map(\.text), ["keep me", "disk text"])
        XCTAssertEqual(snapshot.windows.first?.documents.last?.sourceURL, url)
    }

    func testPreviewUnderlapsToolbar() async throws {
        _ = NSApplication.shared
        let manager = WindowManager()
        let state = manager.openNewWindow()
        let window = try XCTUnwrap(state.hostWindow)
        defer { window.delegate = nil; window.close() }
        let document = try XCTUnwrap(state.selectedDocument)
        document.language = .markdown
        document.isPreviewVisible = true
        document.text = "# Title\n\n" + String(repeating: "Paragraph\n\n", count: 100)
        try await Task.sleep(for: .seconds(2))
        func findWebView(_ view: NSView) -> WKWebView? {
            if let webView = view as? WKWebView { return webView }
            return view.subviews.lazy.compactMap { findWebView($0) }.first
        }
        let webView = try XCTUnwrap(findWebView(try XCTUnwrap(window.contentView)))
        XCTAssertFalse(window.titlebarAppearsTransparent,
                       "AppKit supplies the native NT2 titlebar backdrop")
        func materials(_ view: NSView) -> [NSVisualEffectView] {
            let own = (view as? NSVisualEffectView).map { [$0] } ?? []
            return own + view.subviews.flatMap { materials($0) }
        }
        let chrome = materials(try XCTUnwrap(window.contentView)).filter {
            $0.identifier?.rawValue == "editorTitlebarMaterial"
        }
        XCTAssertTrue(chrome.isEmpty, "Do not reintroduce a material over the native backdrop")
        let frame = webView.convert(webView.bounds, to: nil)
        XCTAssertGreaterThan(frame.maxY, window.contentLayoutRect.maxY)
        XCTAssertGreaterThan(webView.obscuredContentInsets.top, 0)
        window.setContentSize(NSSize(width: 980, height: 620))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(webView.convert(webView.bounds, to: nil).maxY, window.contentLayoutRect.maxY)
        XCTAssertGreaterThan(webView.obscuredContentInsets.top, 0)
    }
    func testOpenAndOrdinarySaveWriteOriginalFile() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("original.txt")
        try "original text".write(to: original, atomically: true, encoding: .utf8)
        let manager = WindowManager()
        let state = AppState(recentFiles: RecentFilesStore(), preferences: AppPreferences())
        manager.openFile(original, preferredState: state)
        for _ in 0..<100 {
            if state.selectedDocument?.ioState != .opening { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let document = try XCTUnwrap(state.selectedDocument)
        let copy = try XCTUnwrap(document.url)
        XCTAssertEqual(copy, original)
        XCTAssertEqual(document.text, "original text")
        document.text = "edited copy"
        XCTAssertTrue(state.save(document))
        for _ in 0..<100 {
            if !state.hasPendingSave { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(state.hasPendingSave)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "edited copy")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "edited copy")
        XCTAssertFalse(document.isDirty)
    }

    func testNewNativeTabPreservesSidebarVisibility() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let savedVisibility = defaults.object(forKey: "isSidebarVisible")
        defer { defaults.set(savedVisibility, forKey: "isSidebarVisible") }

        let manager = WindowManager()
        let source = manager.openNewWindow()
        let window = try XCTUnwrap(source.hostWindow)
        defer {
            for member in window.tabGroup?.windows ?? [window] {
                member.delegate = nil
                member.close()
            }
        }
        func sidebarItem(in view: NSView) -> NSSplitViewItem? {
            if let split = view as? NSSplitView,
               let controller = split.delegate as? NSSplitViewController,
               let item = controller.splitViewItems.first, item.behavior == .sidebar {
                return item
            }
            return view.subviews.lazy.compactMap { sidebarItem(in: $0) }.first
        }

        try await Task.sleep(for: .milliseconds(300))
        var previous = source
        for (isVisible, defaultVisibility) in [(false, false), (false, true), (true, false)] {
            previous.isSidebarVisible = isVisible
            try await Task.sleep(for: .milliseconds(200))
            let previousWindow = try XCTUnwrap(previous.hostWindow)
            let previousItem = try XCTUnwrap(sidebarItem(in: XCTUnwrap(previousWindow.contentView)))
            XCTAssertEqual(previousItem.isCollapsed, !isVisible)

            // A different window may have last written the global preference.
            defaults.set(defaultVisibility, forKey: "isSidebarVisible")
            let tab = manager.openNativeTab(from: previous)
            XCTAssertEqual(tab.isSidebarVisible, isVisible)
            let tabWindow = try XCTUnwrap(tab.hostWindow)
            try await Task.sleep(for: .milliseconds(300))

            XCTAssertTrue(window.tabGroup?.windows.contains(tabWindow) == true)
            XCTAssertEqual(tab.isSidebarVisible, isVisible)
            XCTAssertEqual(previous.isSidebarVisible, isVisible)
            let item = try XCTUnwrap(sidebarItem(in: XCTUnwrap(tabWindow.contentView)))
            XCTAssertEqual(item.isCollapsed, !isVisible)
            previous = tab
        }
    }

    func testRealWindowCloseReopenAndCreateTab() async throws {
        _ = NSApplication.shared
        let manager = WindowManager()
        let first = manager.openNewWindow()
        try await Task.sleep(for: .milliseconds(300))
        let firstWindow = try XCTUnwrap(first.hostWindow)
        let second = manager.openNativeTab(from: first)
        try await Task.sleep(for: .milliseconds(300))
        let secondWindow = try XCTUnwrap(second.hostWindow)
        XCTAssertEqual(firstWindow.tabGroup?.windows.count, 2)
        XCTAssertEqual(first.documents.count, 1)
        XCTAssertEqual(second.documents.count, 1)
        second.closeSelectedDocument()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(secondWindow.isVisible)
        first.closeSelectedDocument()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(firstWindow.isVisible)
        manager.reopenPrimaryWindow()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(firstWindow.isVisible)
        XCTAssertTrue(manager.activeState === first)
        XCTAssertTrue(first.selectedDocument?.isDisposableBlank == true)
        let third = manager.openNativeTab(from: first)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(firstWindow.tabGroup?.windows.count, 2)
        third.closeSelectedDocument()
        first.closeSelectedDocument()
    }

    func testSystemTabGroupSelectionAndDetachKeepDocumentOwnership() throws {
        _ = NSApplication.shared
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: first.frame,
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        defer { first.close(); second.close() }
        let a = AppState(initialDocument: EditorDocument(text: "first"), recentFiles: RecentFilesStore(), preferences: AppPreferences())
        let b = AppState(initialDocument: EditorDocument(text: "second"), recentFiles: RecentFilesStore(), preferences: AppPreferences())
        a.hostWindow = first
        b.hostWindow = second
        configureEditorWindowChrome(first, appState: a)
        configureEditorWindowChrome(second, appState: b)
        first.addTabbedWindow(second, ordered: .above)
        let group = try XCTUnwrap(first.tabGroup)
        XCTAssertEqual(group.windows.count, 2)
        a.selectTab(at: 1)
        XCTAssertTrue(group.selectedWindow === second)
        group.removeWindow(second)
        XCTAssertFalse(first.tabGroup?.windows.contains(second) == true)
        XCTAssertEqual(a.documents.count, 1)
        XCTAssertEqual(b.documents.count, 1)
        XCTAssertEqual(a.selectedDocument?.text, "first")
        XCTAssertEqual(b.selectedDocument?.text, "second")
    }

    func testApprovedPrimaryCloseResetsDocumentAndCanRebind() {
        _ = NSApplication.shared
        let manager = WindowManager()
        let state = AppState(initialDocument: EditorDocument(text: "closed content"), recentFiles: RecentFilesStore(), preferences: AppPreferences())
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let id = UUID()
        manager.register(windowID: id, state: state, window: window)
        manager.unregister(windowID: id)
        XCTAssertEqual(state.documents.count, 1)
        XCTAssertTrue(state.selectedDocument?.isDisposableBlank == true)
        manager.register(windowID: id, state: state, window: window)
        XCTAssertTrue(manager.activeState === state)
        XCTAssertTrue(state.hostWindow === window)
        XCTAssertEqual(state.selectedDocument?.text, "")
    }
}
