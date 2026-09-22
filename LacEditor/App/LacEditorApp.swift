import AppKit
import SwiftUI

@main
@MainActor
struct LacEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState
    @StateObject private var windowManager: WindowManager
    private let primaryWindowID: UUID

    init() {
        let manager = WindowManager(
            recoveryStore: DocumentRecoveryStore(),
            workspaceStore: WorkspaceSessionStore()
        )
        let recoveredDocuments = manager.takeRecoveredDocuments()
        let state = AppState(
            initialDocuments: recoveredDocuments,
            recentFiles: manager.recentFiles,
            preferences: manager.preferences,
            recoveryStore: manager.recoveryStore
        )
        state.windowManager = manager
        let windowID = UUID()
        _appState = StateObject(wrappedValue: state)
        _windowManager = StateObject(wrappedValue: manager)
        primaryWindowID = windowID
        AppDelegate.sharedManager = manager
    }

    var body: some Scene {
        Window("LacEditor", id: "main") {
            EditorWindowRoot(
                appState: appState,
                windowManager: windowManager,
                windowID: primaryWindowID
            )
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            LacEditorCommands(windowManager: windowManager)
        }

    }
}

struct SettingsHostView: View {
    @ObservedObject var fallbackState: AppState
    @ObservedObject var windowManager: WindowManager

    private var targetState: AppState {
        windowManager.activeState ?? fallbackState
    }

    var body: some View {
        SettingsView()
            .environmentObject(targetState)
            .preferredColorScheme(targetState.preferredColorScheme)
            .tint(Color(red: 0.31, green: 0.34, blue: 0.66))
            .background(
                WindowThemeCoordinator(
                    theme: targetState.theme,
                    systemAppearanceDidChange: targetState.refreshSystemAppearance
                )
            )
    }
}

/// Presents settings as a normal, non-modal macOS utility window. A sidebar
/// hosted inside NSSplitViewController does not always inherit SwiftUI's
/// `openSettings` action, which can create a Settings scene behind the editor
/// and immediately return focus to the main window. Keeping one explicit
/// controller makes the button deterministic and keeps the window in front.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var windowController: NSWindowController?

    func present(windowManager: WindowManager) {
        guard let state = windowManager.activeState else { return }

        if let window = windowController?.window {
            window.contentViewController = NSHostingController(
                rootView: SettingsHostView(
                    fallbackState: state,
                    windowManager: windowManager
                )
            )
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 570),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.contentViewController = NSHostingController(
            rootView: SettingsHostView(
                fallbackState: state,
                windowManager: windowManager
            )
        )
        window.minSize = NSSize(width: 500, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        windowController = nil
    }
}

struct EditorWindowRoot: View {
    @ObservedObject var appState: AppState
    @ObservedObject var windowManager: WindowManager
    let windowID: UUID

    var body: some View {
        MainWindowView()
            .environmentObject(appState)
            .environmentObject(windowManager)
            .preferredColorScheme(appState.preferredColorScheme)
            .tint(Color(red: 0.31, green: 0.34, blue: 0.66))
            .frame(minWidth: 900, minHeight: 560)
            .background(
                WindowCloseCoordinator(
                    appState: appState,
                    windowManager: windowManager,
                    windowID: windowID
                )
            )
            .background(
                WindowThemeCoordinator(
                    theme: appState.theme,
                    systemAppearanceDidChange: appState.refreshSystemAppearance
                )
            )
    }
}

private struct WindowThemeCoordinator: NSViewRepresentable {
    let theme: AppTheme
    let systemAppearanceDidChange: () -> Void

    func makeNSView(context: Context) -> AppearanceObserverView {
        let view = AppearanceObserverView()
        view.systemAppearanceDidChange = systemAppearanceDidChange
        applyTheme(to: view)
        return view
    }

    func updateNSView(_ nsView: AppearanceObserverView, context: Context) {
        nsView.systemAppearanceDidChange = systemAppearanceDidChange
        applyTheme(to: nsView)
    }

    private func applyTheme(to view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let targetAppearance: NSAppearance?
            switch theme {
            case .system:
                targetAppearance = nil
            case .light:
                targetAppearance = NSAppearance(named: .aqua)
            case .dark:
                targetAppearance = NSAppearance(named: .darkAqua)
            }
            if window.appearance?.name != targetAppearance?.name {
                window.appearance = targetAppearance
            }
            window.contentView?.needsDisplay = true
        }
    }

    final class AppearanceObserverView: NSView {
        var systemAppearanceDidChange: (() -> Void)?

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            DispatchQueue.main.async { [weak self] in
                self?.systemAppearanceDidChange?()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedManager: WindowManager?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // SwiftUI's Window scene may consume Finder's open-document event
        // before application(_:open:) is called. Intercept the AppKit event
        // directly so an existing workspace stays alive and receives the URL.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
        // SwiftUI installs its command menus during scene construction, which
        // happens after WindowManager is initialized. Translate once again at
        // the AppKit launch boundary and after the scene has had a run-loop
        // turn to create the menu hierarchy.
        DispatchQueue.main.async {
            MenuLocalizationController.localizeMainMenu()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MenuLocalizationController.localizeMainMenu()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        // Finder's document event can briefly close the SwiftUI scene while
        // routing the file. Keep the application alive so the existing
        // workspace and unsaved tabs are not discarded.
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            Self.sharedManager?.reopenPrimaryWindow()
        }
        return true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        Self.sharedManager?.reopenPrimaryWindow()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openFilesFromFinder(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openFilesFromFinder(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    private func openFilesFromFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Self.sharedManager?.openFilesFromFinder(urls)
    }

    @objc private func handleOpenDocuments(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard let directObject = event.paramDescriptor(forKeyword: keyDirectObject) else {
            return
        }

        var urls: [URL] = []
        if directObject.numberOfItems > 0 {
            for index in 1...directObject.numberOfItems {
                if let url = directObject.atIndex(index)?.fileURLValue {
                    urls.append(url)
                }
            }
        } else if let url = directObject.fileURLValue {
            urls.append(url)
        }
        openFilesFromFinder(urls)
    }

    func applicationDidResignActive(_ notification: Notification) {
        Self.sharedManager?.persistRecoverySnapshotsImmediately()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // The SwiftUI command tree can be rebuilt when the first window is
        // activated. Re-apply the visible top-level labels after that rebuild.
        MenuLocalizationController.localizeMainMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MenuLocalizationController.localizeMainMenu()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            MenuLocalizationController.localizeMainMenu()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager = Self.sharedManager else { return .terminateNow }
        let finish = { shouldTerminate in
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        manager.requestApplicationTermination(completion: finish)
        return .terminateLater
    }
}

@MainActor
final class AppearanceMenuController: NSObject {
    private weak var windowManager: WindowManager?
    private var observer: NSObjectProtocol?

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
        super.init()
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let menu = notification.object as? NSMenu,
                      menu.items.contains(where: { $0.title == "外观" }) else {
                    return
                }
                self?.installNativeSubmenu(in: menu)
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.installFromMainMenu()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func installFromMainMenu() {
        guard let viewMenu = NSApp.mainMenu?.items.first(where: {
            $0.title == "显示"
        })?.submenu else { return }
        installNativeSubmenu(in: viewMenu)
    }

    private func installNativeSubmenu(in viewMenu: NSMenu) {
        guard let appearanceItem = viewMenu.items.first(where: {
            $0.title == "外观"
        }) else { return }

        if appearanceItem.identifier?.rawValue == "LacEditor.Appearance",
           let submenu = appearanceItem.submenu {
            updateItems(in: submenu)
            appearanceItem.isEnabled = windowManager?.activeState != nil
            return
        }

        let submenu = NSMenu(title: "外观")
        submenu.autoenablesItems = false
        appearanceItem.identifier = NSUserInterfaceItemIdentifier(
            "LacEditor.Appearance"
        )
        for theme in AppTheme.allCases {
            let item = NSMenuItem(
                title: theme.rawValue,
                action: #selector(selectTheme(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = theme.rawValue
            item.identifier = NSUserInterfaceItemIdentifier(
                "LacEditor.Theme.\(theme.id)"
            )
            item.isEnabled = windowManager?.activeState != nil
            item.state = windowManager?.activeState?.theme == theme ? .on : .off
            submenu.addItem(item)
        }
        appearanceItem.submenu = submenu
        appearanceItem.isEnabled = windowManager?.activeState != nil
    }

    private func updateItems(in submenu: NSMenu) {
        for item in submenu.items {
            guard let rawValue = item.representedObject as? String,
                  let theme = AppTheme(rawValue: rawValue) else { continue }
            item.isEnabled = windowManager?.activeState != nil
            item.state = windowManager?.activeState?.theme == theme ? .on : .off
        }
    }

    @objc
    private func selectTheme(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let theme = AppTheme(rawValue: rawValue) else { return }
        windowManager?.activeState?.theme = theme
    }
}

/// SwiftUI's standard command groups inherit the system's English menu names
/// when the app has no localization bundle. Keep the command implementation
/// intact and translate only the visible top-level menu labels.
@MainActor
final class MenuLocalizationController: NSObject {
    private var observer: NSObjectProtocol?
    private var localizationAttempts = 0

    override init() {
        super.init()
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self != nil else { return }
                Self.localizeMainMenu()
                // SwiftUI may refresh the command hierarchy immediately when
                // tracking starts. Apply one more pass after that refresh.
                DispatchQueue.main.async {
                    Self.localizeMainMenu()
                }
            }
        }
        // SwiftUI creates the command menu after the App initializer returns.
        // Retry briefly after launch so the native menu is translated after it
        // actually exists, rather than relying on a single early pass.
        scheduleLocalizationPass()
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    static func localizeMainMenu() {
        guard let menu = NSApp.mainMenu else { return }
        let translations = [
            "File": "文件",
            "Edit": "编辑",
            "View": "显示",
            "Window": "窗口",
            "Help": "帮助"
        ]
        for item in menu.items {
            if let translated = translations[item.title] {
                item.title = translated
            }
        }
    }

    private func scheduleLocalizationPass() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            Self.localizeMainMenu()
            self.localizationAttempts += 1
            if self.localizationAttempts < 40 {
                try? await Task.sleep(for: .milliseconds(100))
                self.scheduleLocalizationPass()
            }
        }
    }
}

struct WindowCloseCoordinator: NSViewRepresentable {
    let appState: AppState
    let windowManager: WindowManager
    let windowID: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(
            appState: appState,
            windowManager: windowManager,
            windowID: windowID
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.previousDelegate = window.delegate
            window.delegate = context.coordinator
            window.title = appState.windowTitle
            configureEditorWindowChrome(window, appState: appState)
            windowManager.register(windowID: windowID, state: appState, window: window)
            context.coordinator.scheduleChromeUpdate(for: window)
            MenuLocalizationController.localizeMainMenu()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MenuLocalizationController.localizeMainMenu()
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.title = appState.windowTitle
        if let window = nsView.window {
            configureEditorWindowChrome(window, appState: appState)
            context.coordinator.scheduleChromeUpdate(for: window)
        }
        if let window = nsView.window, appState.hostWindow !== window {
            windowManager.register(windowID: windowID, state: appState, window: window)
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        let appState: AppState
        let windowManager: WindowManager
        let windowID: UUID
        weak var previousDelegate: NSWindowDelegate?
        private var chromeWorkItem: DispatchWorkItem?
        private var isWaitingForSave = false
        private var isCloseApproved = false

        init(appState: AppState, windowManager: WindowManager, windowID: UUID) {
            self.appState = appState
            self.windowManager = windowManager
            self.windowID = windowID
        }

        deinit {
            chromeWorkItem?.cancel()
        }

        func scheduleChromeUpdate(for window: NSWindow) {
            chromeWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak window] in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    configureEditorWindowChrome(window, appState: self.appState)
                }
            }
            chromeWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.2,
                execute: workItem
            )
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if windowManager.terminationApproved || isCloseApproved {
                return true
            }
            if appState.hasPendingSave {
                guard !isWaitingForSave else { return false }
                isWaitingForSave = true
                appState.waitForPendingSaves { [weak self, weak sender] in
                    guard let self, let sender else { return }
                    isWaitingForSave = false
                    appState.confirmClosingAllDocuments { [weak self, weak sender] approved in
                        guard let self, let sender, approved else { return }
                        appState.prepareForApprovedWindowClose()
                        isCloseApproved = true
                        sender.performClose(nil)
                    }
                }
                return false
            }
            guard !isWaitingForSave else { return false }
            isWaitingForSave = true
            appState.confirmClosingAllDocuments { [weak self, weak sender] approved in
                guard let self, let sender else { return }
                isWaitingForSave = false
                if approved {
                    appState.prepareForApprovedWindowClose()
                    isCloseApproved = true
                    sender.performClose(nil)
                }
            }
            return false
        }

        func windowDidBecomeKey(_ notification: Notification) {
            // A SwiftUI Window scene may be reopened from the Dock after it
            // was closed. Rebind the existing session before activating it so
            // menu commands and sidebar state target this window again.
            if let window = notification.object as? NSWindow {
                windowManager.register(
                    windowID: windowID,
                    state: appState,
                    window: window
                )
            }
            windowManager.activate(windowID: windowID)
            previousDelegate?.windowDidBecomeKey?(notification)
        }

        func windowWillClose(_ notification: Notification) {
            windowManager.unregister(windowID: windowID)
            previousDelegate?.windowWillClose?(notification)
        }
    }
}

@MainActor
func configureEditorWindowChrome(_ window: NSWindow, appState: AppState? = nil) {
    // This is the same structure used by Finder: the native split sidebar is
    // allowed to extend through the titlebar, while one compact AppKit toolbar
    // owns every titlebar control and tracks the split-view divider.
    window.styleMask.insert(.fullSizeContentView)
    window.toolbarStyle = .unified
    window.titleVisibility = .hidden
    // Let the native full-height sidebar material continue behind the
    // traffic-light/titlebar area, as it does in Finder.
    window.titlebarAppearsTransparent = true
    window.backgroundColor = .windowBackgroundColor
    window.titlebarSeparatorStyle = .none

    if let appState {
        configureEditorWindowToolbar(window, appState: appState)
    }
}
