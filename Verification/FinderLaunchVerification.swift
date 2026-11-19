import AppKit
import ApplicationServices

/// Real Launch Services cold/warm events. Only the acceptance identity and a
/// temporary home are allowed; no Dock reopen is sent before cold assertions.
@main
struct FinderLaunchVerification {
    static let identifier = "com.laceditor.acceptance"
    struct Failure: Error { let message: String }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func elements(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 24 else { return [] }
        return [element] + (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            .flatMap { elements($0, depth: depth + 1) }
    }
    static func windows(_ app: NSRunningApplication) -> [AXUIElement] {
        attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
    }
    static func title(_ element: AXUIElement) -> String {
        attribute(element, kAXTitleAttribute) as? String ?? ""
    }
    static func text(_ app: NSRunningApplication) -> String? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = attribute(application, kAXFocusedWindowAttribute),
              let area = elements(window as! AXUIElement).first(where: {
                  attribute($0, kAXRoleAttribute) as? String == kAXTextAreaRole
              }) else { return nil }
        return attribute(area, kAXValueAttribute) as? String
    }
    static func key(_ code: CGKeyCode, app: NSRunningApplication, flags: CGEventFlags = .maskCommand) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.postToPid(app.processIdentifier)
        }
    }
    static func hasVisibleSidebar(_ app: NSRunningApplication) -> Bool {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = attribute(application, kAXFocusedWindowAttribute) else { return false }
        return elements(window as! AXUIElement).contains {
            let label = title($0) + (attribute($0, kAXDescriptionAttribute) as? String ?? "")
                + (attribute($0, kAXValueAttribute) as? String ?? "")
            return label.contains("最近文件")
        }
    }
    static func insert(_ value: String, app: NSRunningApplication) throws {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let window = try attribute(application, kAXFocusedWindowAttribute).unwrap("focused editor")
        let area = try elements(window as! AXUIElement).first {
            attribute($0, kAXRoleAttribute) as? String == kAXTextAreaRole
        }.unwrap("text area")
        AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let units = Array(value.utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            units.withUnsafeBufferPointer {
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress!)
            }
            event?.postToPid(app.processIdentifier)
        }
    }
    @MainActor
    static func wait(_ label: String, until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        repeat {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw Failure(message: "timeout: " + label)
    }
    @MainActor
    static func launch(_ appURL: URL, home: URL, files: [URL]) async throws -> NSRunningApplication {
        try require(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty, "acceptance App already running")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.environment = ["CFFIXED_USER_HOME": home.path]
        config.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        let app: NSRunningApplication
        if files.isEmpty {
            app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        } else {
            app = try await NSWorkspace.shared.open(files, withApplicationAt: appURL, configuration: config)
        }
        try require(app.bundleIdentifier == identifier && app.bundleURL?.standardizedFileURL == appURL, "wrong App launched")
        return app
    }
    @MainActor
    static func open(_ file: URL, appURL: URL, app: NSRunningApplication) async throws {
        let result = try await NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        try require(result.processIdentifier == app.processIdentifier && !app.isTerminated, "Finder restarted App")
        try await wait("opened " + file.lastPathComponent) { windows(app).contains { title($0).contains(file.lastPathComponent) } }
    }
    @MainActor
    static func quit(_ app: NSRunningApplication) async throws {
        _ = app.terminate()
        try await wait("graceful exit") { app.isTerminated }
    }
    static func snapshotTexts(home: URL) throws -> [String] {
        let root = home.appendingPathComponent("Library/Application Support/LacEditor-Acceptance/Workspace")
        let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("CurrentWorkspace.json"))) as! [String: String]
        let folder = root.appendingPathComponent("Workspace-" + marker["workspaceID"]!.lowercased())
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("Manifest.json"))) as! [String: Any]
        return try (manifest["windows"] as! [[String: Any]]).flatMap { $0["documents"] as! [[String: Any]] }.map {
            try String(contentsOf: folder.appendingPathComponent($0["contentFileName"] as! String), encoding: .utf8)
        }
    }
    @MainActor
    static func verifySidebar(_ appURL: URL, home: URL) async throws {
        let app = try await launch(appURL, home: home, files: [])
        defer { if !app.isTerminated { _ = app.forceTerminate() } }
        try await wait("blank editor with sidebar") { text(app) == "" && hasVisibleSidebar(app) }
        key(11, app: app, flags: [.maskCommand, .maskControl]) // Control+Command+B
        try await wait("sidebar hidden in source tab") { text(app) == "" && !hasVisibleSidebar(app) }
        try insert("source tab", app: app)
        try await wait("source text visible") { text(app) == "source tab" }
        key(17, app: app) // Command+T
        try await wait("new blank tab") { text(app) == "" }
        try await Task.sleep(for: .milliseconds(400))
        try require(text(app) == "" && !hasVisibleSidebar(app), "Command+T reopened the hidden sidebar")
        key(11, app: app, flags: [.maskCommand, .maskControl])
        try await wait("sidebar responds to toggle in new tab") { hasVisibleSidebar(app) }
        try await quit(app)
        print("PASS Command+T preserves hidden sidebar; toggling it still works")
    }
    @MainActor
    static func verify(_ appURL: URL, multiple: Bool, sidebarOnly: Bool = false) async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("LacEditor-Finder-\(UUID())")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let prefs = home.appendingPathComponent("Library/Preferences")
        try fm.createDirectory(at: prefs, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "hasConfirmedWorkspaceExitPrompt": true, "workspaceExitBehavior": "preserveWorkspace",
            "isSidebarVisible": true
        ], format: .xml, options: 0).write(to: prefs.appendingPathComponent(identifier + ".plist"))
        if sidebarOnly {
            try await verifySidebar(appURL, home: home)
            return
        }
        let first = home.appendingPathComponent("冷启动.txt")
        let second = home.appendingPathComponent("第二个.md")
        let third = home.appendingPathComponent("工作区恢复.json")
        for (url, content) in [(first, "cold file content\n"), (second, "# Markdown\n"), (third, "{\"restored\":true}\n")] {
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        let app = try await launch(appURL, home: home, files: multiple ? [first, second] : [first])
        defer { if !app.isTerminated { _ = app.forceTerminate() } }
        try await wait("cold file visible without Dock") { text(app) == (multiple ? "# Markdown\n" : "cold file content\n") }
        print("PASS cold \(multiple ? "multiple" : "single") files, no Dock event; PID=\(app.processIdentifier)")
        if multiple {
            key(17, app: app) // Command+T
            try await wait("new blank tab") { text(app) == "" }
            let draft = "未保存的工作区草稿\n"
            try insert(draft, app: app)
            try await wait("insert draft") { text(app) == draft }
            try await open(first, appURL: appURL, app: app)
            try await quit(app)
            let saved = try snapshotTexts(home: home)
            try require(saved.count == 3 && saved.contains(draft) && saved.contains("# Markdown\n"), "warm event lost or duplicated documents")
            let restored = try await launch(appURL, home: home, files: [third])
            defer { if !restored.isTerminated { _ = restored.forceTerminate() } }
            try await Task.sleep(for: .milliseconds(1000))
            print("restore windows=\(windows(restored).map { title($0) }) focusedText=\(text(restored) ?? "nil")")
            fflush(stdout)
            try await wait("restored workspace + cold file visible") { text(restored) == "{\"restored\":true}\n" }
            try await quit(restored)
            let after = try snapshotTexts(home: home)
            try require(after.count == 4 && after.contains(draft) && after.contains("cold file content\n"), "cold file lost restored workspace")
            print("PASS warm duplicate open, unsaved draft, graceful exit, workspace restore + cold file")
        } else {
            key(13, app: app) // content -> blank
            try await wait("last content becomes blank") { text(app) == "" }
            key(13, app: app) // blank -> no window
            try await wait("blank closes window") { windows(app).isEmpty }
            try require(!app.isTerminated, "closing last window quit App")
            try await open(second, appURL: appURL, app: app)
            try await wait("Finder reopens no-window App") { text(app) == "# Markdown\n" }
            key(13, app: app)
            try await wait("blank again") { text(app) == "" }
            key(13, app: app)
            try await wait("no window again") { windows(app).isEmpty }
            let reopened = try await NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            try require(reopened.processIdentifier == app.processIdentifier, "Dock restarted App")
            try await wait("Dock reopens blank") { text(app) == "" }
            try await wait("sidebar rebound") { hasVisibleSidebar(app) }
            key(17, app: app)
            try await Task.sleep(for: .milliseconds(400))
            try await quit(app)
            let afterReopen = try snapshotTexts(home: home)
            try require(afterReopen.count == 2, "Command+T failed after reopen")
            print("PASS content -> blank -> no window; Finder/Dock same-PID reopen; sidebar; Command+T/W")
        }
    }
    @MainActor
    static func main() async {
        do {
            try require(CommandLine.arguments.count == 2 && AXIsProcessTrusted(), "App path and Accessibility required")
            let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
            try require(Bundle(url: appURL)?.bundleIdentifier == identifier, "only acceptance App permitted")
            let previous = NSWorkspace.shared.frontmostApplication
            defer { _ = previous?.activate(options: []) }
            try await verify(appURL, multiple: false)
            try await verify(appURL, multiple: true)
            try await verify(appURL, multiple: false, sidebarOnly: true)
            print("Finder launch lifecycle passed.")
        } catch { fputs("Finder verification failed: \(error)\n", stderr); exit(1) }
    }
}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let self else { throw FinderLaunchVerification.Failure(message: message) }
        return self
    }
}
