import AppKit
import XCTest
@testable import LacEditor

@MainActor
final class WindowAndSessionTests: XCTestCase {
    func testRealWindowsRegisterAndCrossWindowTabDragMovesDocument() {
        _ = NSApplication.shared
        let manager = WindowManager()
        let sourceDocument = EditorDocument(text: "source")
        let targetDocument = EditorDocument(text: "target")
        let sourceState = makeState(document: sourceDocument)
        let targetState = makeState(document: targetDocument)
        let sourceWindow = makeWindow(title: "Source")
        let targetWindow = makeWindow(title: "Target")
        let sourceWindowID = UUID()
        let targetWindowID = UUID()
        defer {
            manager.unregister(windowID: sourceWindowID)
            manager.unregister(windowID: targetWindowID)
            sourceWindow.close()
            targetWindow.close()
        }

        manager.register(
            windowID: sourceWindowID,
            state: sourceState,
            window: sourceWindow
        )
        manager.register(
            windowID: targetWindowID,
            state: targetState,
            window: targetWindow
        )

        XCTAssertTrue(sourceState.hostWindow === sourceWindow)
        XCTAssertTrue(targetState.hostWindow === targetWindow)

        manager.beginTabDrag(sourceDocument, from: sourceState)
        manager.setTabDragTarget(in: targetState, before: targetDocument.id)
        XCTAssertTrue(
            manager.acceptTabDrag(
                into: targetState,
                before: targetDocument.id
            )
        )

        XCTAssertFalse(sourceState.documents.contains { $0.id == sourceDocument.id })
        XCTAssertEqual(
            targetState.documents.map(\.id),
            [sourceDocument.id, targetDocument.id]
        )
        XCTAssertEqual(targetState.selectedDocumentID, sourceDocument.id)
    }

    func testTabDragCanPlaceFirstDocumentAtTrailingEnd() {
        let manager = WindowManager()
        let first = EditorDocument(text: "first")
        let state = makeState(document: first)
        state.newDocument()
        state.newDocument()
        let originalIDs = state.documents.map(\.id)

        manager.beginTabDrag(first, from: state)
        manager.setTabDragTarget(in: state, before: nil)
        XCTAssertTrue(manager.acceptTabDrag(into: state, before: nil))

        XCTAssertEqual(
            state.documents.map(\.id),
            [originalIDs[1], originalIDs[2], originalIDs[0]]
        )
        XCTAssertEqual(state.selectedDocumentID, first.id)
    }

    func testEditorSessionCacheUsesLRUAndReturnsRealScrollView() {
        let store = EditorSessionStore(
            limit: 2,
            inactiveMemoryBudget: .max,
            maximumCacheableSessionCost: .max
        )
        let first = EditorDocument(text: "first")
        let second = EditorDocument(text: "second")
        let third = EditorDocument(text: "third")

        let firstView = makeEditorScrollView(text: first.text)
        store.store(
            firstView,
            coordinator: store.coordinator(for: first),
            for: first.id
        )
        store.store(
            makeEditorScrollView(text: second.text),
            coordinator: store.coordinator(for: second),
            for: second.id
        )
        XCTAssertTrue(store.cachedView(for: first.id) === firstView)

        store.store(
            makeEditorScrollView(text: third.text),
            coordinator: store.coordinator(for: third),
            for: third.id
        )

        XCTAssertEqual(store.snapshot.documentIDs, [first.id, third.id])
        XCTAssertFalse(store.snapshot.documentIDs.contains(second.id))
    }

    func testCacheBudgetRejectsOversizedInactiveSession() {
        let store = EditorSessionStore(
            limit: 3,
            inactiveMemoryBudget: 8_000,
            maximumCacheableSessionCost: 4_000
        )
        let document = EditorDocument(text: String(repeating: "x", count: 2_000))
        let coordinator = store.coordinator(for: document)
        store.store(
            makeEditorScrollView(text: document.text),
            coordinator: coordinator,
            for: document.id
        )

        XCTAssertFalse(store.snapshot.documentIDs.contains(document.id))
        XCTAssertEqual(store.snapshot.inactiveMemoryCost, 0)
    }

    func testCriticalMemoryPressureKeepsActiveSessionAndEvictsInactiveSessions() {
        let store = EditorSessionStore(
            limit: 3,
            inactiveMemoryBudget: .max,
            maximumCacheableSessionCost: .max
        )
        let activeDocument = EditorDocument(text: "active")
        let inactiveDocument = EditorDocument(text: "inactive")
        let activeCoordinator = store.coordinator(for: activeDocument)
        store.store(
            makeEditorScrollView(text: activeDocument.text),
            coordinator: activeCoordinator,
            for: activeDocument.id
        )
        activeCoordinator.updateActivity(true)
        store.store(
            makeEditorScrollView(text: inactiveDocument.text),
            coordinator: store.coordinator(for: inactiveDocument),
            for: inactiveDocument.id
        )

        store.processMemoryPressure(.critical)

        XCTAssertEqual(store.snapshot.documentIDs, [activeDocument.id])
        XCTAssertTrue(store.snapshot.inactiveDocumentIDs.isEmpty)
        activeCoordinator.updateActivity(false)
    }

    private func makeState(document: EditorDocument) -> AppState {
        AppState(
            initialDocument: document,
            recentFiles: RecentFilesStore(),
            preferences: AppPreferences()
        )
    }

    private func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeEditorScrollView(text: String) -> NSScrollView {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 420)
        )
        let textView = LacTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 420)
        )
        textView.string = text
        scrollView.documentView = textView
        return scrollView
    }
}
