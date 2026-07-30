import AppKit
import SwiftUI

struct LacEditorCommands: Commands {
    @ObservedObject private var windowManager: WindowManager

    init(windowManager: WindowManager) {
        _windowManager = ObservedObject(wrappedValue: windowManager)
    }

    private var appState: AppState? {
        windowManager.activeState
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建窗口") { windowManager.openNewWindow() }
                .keyboardShortcut("n", modifiers: .command)
            Button("新建标签页") { appState?.newDocument() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(appState == nil)
            Divider()
            Button("打开…") { appState?.openFiles() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(appState == nil)
            Button("打开文件夹…") { appState?.openFolder() }
                .disabled(appState == nil)
            Menu("最近打开的文件") {
                if windowManager.recentFiles.urls.isEmpty {
                    Text("无最近文件")
                } else {
                    ForEach(windowManager.recentFiles.urls, id: \.self) { url in
                        Button(url.lastPathComponent) { appState?.openFile(url) }
                    }
                    Divider()
                    Button("清除菜单") { windowManager.recentFiles.clear() }
                }
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("保存") { appState?.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(appState == nil)
            Button("另存为…") { appState?.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(appState == nil)
            Divider()
            Button("关闭标签页") { appState?.closeSelectedDocument() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(appState == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("查找…") { appState?.presentFindReplace(mode: .find) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(appState == nil)
            Button("查找并替换…") { appState?.presentFindReplace(mode: .replace) }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(appState == nil)
            Button("查找下一个") { appState?.findNext() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(appState == nil)
            Button("查找上一个") { appState?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(appState == nil)
            Divider()
            Button("格式化 JSON") { appState?.formatJSON() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(appState == nil)
            Button("压缩 JSON") { appState?.formatJSON(pretty: false) }
                .disabled(appState == nil)
        }

        CommandGroup(after: .sidebar) {
            Button(appState?.isSidebarVisible == true ? "隐藏侧边栏" : "显示侧边栏") {
                appState?.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(appState == nil)

            Button("切换 Markdown 预览") { appState?.togglePreview() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(appState == nil)
            Button(appState?.isWordWrapEnabled == true ? "关闭自动换行" : "开启自动换行") {
                appState?.isWordWrapEnabled.toggle()
            }
            .disabled(appState == nil)
            Button(appState?.isLineNumbersVisible == true ? "隐藏行号" : "显示行号") {
                appState?.isLineNumbersVisible.toggle()
            }
            .disabled(appState == nil)
            Button(appState?.isStatusBarVisible == true ? "隐藏状态栏" : "显示状态栏") {
                appState?.isStatusBarVisible.toggle()
            }
            .disabled(appState == nil)
            Divider()
            Button("增大字体") { appState?.increaseFontSize() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(appState == nil)
            Button("减小字体") { appState?.decreaseFontSize() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(appState == nil)
            Button("恢复默认字体大小") { appState?.resetFontSize() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(appState == nil)
            Divider()
            Picker(
                "外观",
                selection: Binding(
                    get: { appState?.theme ?? .system },
                    set: { appState?.theme = $0 }
                )
            ) {
                Text(AppTheme.system.rawValue).tag(AppTheme.system)
                Text(AppTheme.light.rawValue).tag(AppTheme.light)
                Text(AppTheme.dark.rawValue).tag(AppTheme.dark)
            }
            .disabled(appState == nil)
        }

        CommandMenu("标签页") {
            Button("上一个标签页") { appState?.selectPreviousTab() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(appState == nil)
            Button("下一个标签页") { appState?.selectNextTab() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(appState == nil)
            Button("切换到下一个标签页") { appState?.selectNextTab() }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(appState == nil)
            Button("切换到上一个标签页") { appState?.selectPreviousTab() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(appState == nil)
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button("切换到第 \(number) 个标签页") {
                    appState?.selectTab(at: number - 1)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(String(number))),
                    modifiers: .command
                )
                .disabled((appState?.documents.count ?? 0) < number)
            }
            Divider()
            Button("折叠/展开当前区块") {
                guard let documentID = appState?.selectedDocumentID else { return }
                NotificationCenter.default.post(
                    name: EditorCommandNotification.toggleFold,
                    object: documentID
                )
            }
            .disabled(appState == nil)
        }
    }

}
