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
        let manager = WindowManager()
        let state = AppState(recentFiles: manager.recentFiles)
        let windowID = UUID()
        _appState = StateObject(wrappedValue: state)
        _windowManager = StateObject(wrappedValue: manager)
        primaryWindowID = windowID
        AppDelegate.sharedManager = manager
    }

    var body: some Scene {
        WindowGroup {
            EditorWindowRoot(
                appState: appState,
                windowManager: windowManager,
                windowID: primaryWindowID
            )
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .commands {
            LacEditorCommands(windowManager: windowManager)
        }

        Settings {
            SettingsHostView(
                fallbackState: appState,
                windowManager: windowManager
            )
        }
        .defaultSize(width: 540, height: 340)
        .windowResizability(.contentSize)
    }
}

private struct SettingsHostView: View {
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedManager: WindowManager?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager = Self.sharedManager else { return .terminateNow }
        return manager.confirmClosingAllWindows() ? .terminateNow : .terminateCancel
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
            windowManager.register(windowID: windowID, state: appState, window: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.title = appState.windowTitle
        if let window = nsView.window, appState.hostWindow !== window {
            windowManager.register(windowID: windowID, state: appState, window: window)
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        let appState: AppState
        let windowManager: WindowManager
        let windowID: UUID
        weak var previousDelegate: NSWindowDelegate?

        init(appState: AppState, windowManager: WindowManager, windowID: UUID) {
            self.appState = appState
            self.windowManager = windowManager
            self.windowID = windowID
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if windowManager.terminationApproved {
                return true
            }
            return appState.confirmClosingAllDocuments()
        }

        func windowDidBecomeKey(_ notification: Notification) {
            windowManager.activate(windowID: windowID)
            previousDelegate?.windowDidBecomeKey?(notification)
        }

        func windowWillClose(_ notification: Notification) {
            windowManager.unregister(windowID: windowID)
            previousDelegate?.windowWillClose?(notification)
        }
    }
}
