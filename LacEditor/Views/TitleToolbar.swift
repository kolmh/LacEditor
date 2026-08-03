import SwiftUI

struct LacEditorToolbar: ToolbarContent {
    @EnvironmentObject private var appState: AppState

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) {
                sidebarToggle
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .navigation) {
                windowTitle
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarSpacer(.flexible)
        } else {
            ToolbarItem(placement: .navigation) {
                sidebarToggle
            }

            ToolbarItem(placement: .navigation) {
                windowTitle
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if let document = appState.selectedDocument {
                Button {
                    post(EditorCommandNotification.undo, documentID: document.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .stableHelp("撤销", shortcut: "⌘Z")

                Button {
                    post(EditorCommandNotification.redo, documentID: document.id)
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .stableHelp("重做", shortcut: "⇧⌘Z")

                Menu {
                    ForEach(EditorLanguage.allCases) { language in
                        Button {
                            appState.setLanguage(language)
                        } label: {
                            if document.language == language {
                                Label(language.rawValue, systemImage: "checkmark")
                            } else {
                                Text(language.rawValue)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: document.language.icon)
                        Text(document.language.rawValue)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 112)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .stableHelp("语言模式")

                if document.language == .markdown {
                    Button {
                        appState.togglePreview()
                    } label: {
                        Image(systemName: document.isPreviewEffectivelyEnabled ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                    }
                    .accessibilityLabel(
                        document.isPreviewEffectivelyEnabled
                            ? "隐藏 Markdown 预览"
                            : "显示 Markdown 预览"
                    )
                    .stableHelp(
                        document.isPreviewEffectivelyEnabled ? "隐藏 Markdown 预览" : "显示 Markdown 预览",
                        shortcut: "⌥⌘P"
                    )
                }
            }
        }
    }

    private var sidebarToggle: some View {
        Button {
            appState.toggleSidebar()
        } label: {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(appState.isSidebarVisible ? "隐藏侧边栏" : "显示侧边栏")
        .stableHelp(
            appState.isSidebarVisible ? "隐藏侧边栏" : "显示侧边栏",
            shortcut: "⌃⌘S"
        )
        .onHover(perform: appState.sidebarPreviewHoverChanged)
    }

    private var windowTitle: some View {
        Text(appState.windowTitle)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 320, alignment: .leading)
            .padding(.leading, appState.isSidebarVisible ? 144 : 0)
            .animation(
                .easeOut(duration: 0.18),
                value: appState.isSidebarVisible
            )
            .accessibilityAddTraits(.isHeader)
    }

    private func post(_ name: Notification.Name, documentID: UUID) {
        NotificationCenter.default.post(name: name, object: documentID)
    }
}
