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
            Button {
                windowManager.openNewWindow()
            } label: {
                Label("新建窗口", systemImage: "macwindow.badge.plus")
            }
                .keyboardShortcut("n", modifiers: .command)
            Button {
                appState?.newDocument()
            } label: {
                Label("新建标签页", systemImage: "plus.square.on.square")
            }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(appState == nil)
            Divider()
            Button {
                appState?.openFiles()
            } label: {
                Label("打开…", systemImage: "doc")
            }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(appState == nil)
            Button {
                appState?.openFolder()
            } label: {
                Label("打开文件夹…", systemImage: "folder")
            }
                .disabled(appState == nil)
            Menu {
                if windowManager.recentFiles.urls.isEmpty {
                    Text("无最近文件")
                } else {
                    ForEach(windowManager.recentFiles.urls, id: \.self) { url in
                        Button {
                            appState?.openFile(url)
                        } label: {
                            Label(url.lastPathComponent, systemImage: "doc.text")
                        }
                    }
                    Divider()
                    Button {
                        windowManager.requestClearRecentFiles()
                    } label: {
                        Label("清除菜单", systemImage: "trash")
                    }
                }
            } label: {
                Label("最近打开的文件", systemImage: "clock")
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button {
                appState?.save()
            } label: {
                Label("保存", systemImage: "square.and.arrow.down")
            }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(appState == nil)
            Button {
                appState?.saveAs()
            } label: {
                Label("另存为…", systemImage: "square.and.arrow.down.on.square")
            }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(appState == nil)
            Divider()
            Button {
                appState?.closeSelectedDocument()
            } label: {
                Label("关闭标签页", systemImage: "xmark.square")
            }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(appState == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button {
                appState?.presentFindReplace(mode: .find)
            } label: {
                Label("查找…", systemImage: "magnifyingglass")
            }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(appState == nil)
            Button {
                appState?.presentFindReplace(mode: .replace)
            } label: {
                Label("查找并替换…", systemImage: "arrow.triangle.2.circlepath")
            }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(appState == nil)
            Button {
                appState?.findNext()
            } label: {
                Label("查找下一个", systemImage: "chevron.down")
            }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(appState == nil)
            Button {
                appState?.findPrevious()
            } label: {
                Label("查找上一个", systemImage: "chevron.up")
            }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(appState == nil)
            Divider()
            Button {
                appState?.formatJSON()
            } label: {
                Label("格式化 JSON", systemImage: "text.alignleft")
            }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(appState == nil)
            Button {
                appState?.formatJSON(pretty: false)
            } label: {
                Label("压缩 JSON", systemImage: "arrow.down.right.and.arrow.up.left")
            }
                .disabled(appState == nil)
        }

        CommandGroup(replacing: .sidebar) {
            Button {
                appState?.toggleSidebar()
            } label: {
                Label(
                    appState?.isSidebarVisible == true ? "隐藏侧边栏" : "显示侧边栏",
                    systemImage: "sidebar.left"
                )
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(appState == nil)

            Button {
                appState?.togglePreview()
            } label: {
                Label("切换 Markdown 预览", systemImage: "rectangle.split.2x1")
            }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(appState == nil)
            Button {
                appState?.isWordWrapEnabled.toggle()
            } label: {
                Label(
                    appState?.isWordWrapEnabled == true ? "关闭自动换行" : "开启自动换行",
                    systemImage: "text.justify.left"
                )
            }
            .disabled(appState == nil)
            Button {
                appState?.isLineNumbersVisible.toggle()
            } label: {
                Label(
                    appState?.isLineNumbersVisible == true ? "隐藏行号" : "显示行号",
                    systemImage: "list.number"
                )
            }
            .disabled(appState == nil)
            Button {
                appState?.isStatusBarVisible.toggle()
            } label: {
                Label(
                    appState?.isStatusBarVisible == true ? "隐藏状态栏" : "显示状态栏",
                    systemImage: "rectangle.bottomthird.inset.filled"
                )
            }
            .disabled(appState == nil)
            Divider()
            Button {
                appState?.increaseFontSize()
            } label: {
                Label("增大字体", systemImage: "plus.magnifyingglass")
            }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(appState == nil)
            Button {
                appState?.decreaseFontSize()
            } label: {
                Label("减小字体", systemImage: "minus.magnifyingglass")
            }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(appState == nil)
            Button {
                appState?.resetFontSize()
            } label: {
                Label("恢复默认字体大小", systemImage: "textformat.size")
            }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(appState == nil)
            Divider()
            Picker(
                selection: Binding(
                    get: { appState?.theme ?? .system },
                    set: { appState?.theme = $0 }
                ),
                label: Label("外观", systemImage: "circle.lefthalf.filled")
            ) {
                Label(AppTheme.system.rawValue, systemImage: "circle.lefthalf.filled")
                    .tag(AppTheme.system)
                Label(AppTheme.light.rawValue, systemImage: "sun.max")
                    .tag(AppTheme.light)
                Label(AppTheme.dark.rawValue, systemImage: "moon")
                    .tag(AppTheme.dark)
            }
            .disabled(appState == nil)
        }

        CommandMenu("标签页") {
            Button {
                appState?.selectPreviousTab()
            } label: {
                Label("上一个标签页", systemImage: "chevron.left")
            }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(appState == nil)
            Button {
                appState?.selectNextTab()
            } label: {
                Label("下一个标签页", systemImage: "chevron.right")
            }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(appState == nil)
            Button {
                appState?.selectNextTab()
            } label: {
                Label("切换到下一个标签页", systemImage: "arrow.right.to.line")
            }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(appState == nil)
            Button {
                appState?.selectPreviousTab()
            } label: {
                Label("切换到上一个标签页", systemImage: "arrow.left.to.line")
            }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(appState == nil)
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button {
                    appState?.selectTab(at: number - 1)
                } label: {
                    Label(
                        "切换到第 \(number) 个标签页",
                        systemImage: "\(number).square"
                    )
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(String(number))),
                    modifiers: .command
                )
                .disabled((appState?.documents.count ?? 0) < number)
            }
            Divider()
            Button {
                guard let documentID = appState?.selectedDocumentID else { return }
                NotificationCenter.default.post(
                    name: EditorCommandNotification.toggleFold,
                    object: documentID
                )
            } label: {
                Label("折叠/展开当前区块", systemImage: "chevron.up.chevron.down")
            }
            .disabled(appState == nil)
        }
    }

}
