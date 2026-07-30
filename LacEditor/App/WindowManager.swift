import AppKit
import Combine
import SwiftUI

@MainActor
final class WindowManager: ObservableObject {
    let recentFiles = RecentFilesStore()
    @Published private(set) var activeState: AppState?
    private(set) var terminationApproved = false

    private var states: [UUID: AppState] = [:]
    private var windowControllers: [UUID: NSWindowController] = [:]
    private var activeStateCancellable: AnyCancellable?
    private var recentFilesCancellable: AnyCancellable?

    init() {
        recentFilesCancellable = recentFiles.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
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
    func openNewWindow(with document: EditorDocument? = nil) -> AppState {
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
        window.center()
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

    func detach(_ document: EditorDocument, from state: AppState) {
        guard let transferred = state.takeDocumentForTransfer(document) else { return }
        openNewWindow(with: transferred)
    }

    func confirmClosingAllWindows() -> Bool {
        terminationApproved = false
        for state in states.values where !state.confirmClosingAllDocuments() {
            return false
        }
        terminationApproved = true
        return true
    }
}
