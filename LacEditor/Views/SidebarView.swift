import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var isSettingsHovering = false

    var body: some View {
        VStack(spacing: 0) {
            RecentFilesView(store: appState.recentFiles)

            Divider()
                .opacity(0.45)

            Button {
                openSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(isSettingsHovering ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .stableHelp("打开设置", shortcut: "⌘,")
            .frame(height: 35)
            .background(
                isSettingsHovering ? Color.primary.opacity(0.05) : .clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .onHover { isSettingsHovering = $0 }
        }
        .background {
            ZStack {
                LacSidebarMaterial()
                Color(nsColor: .lacEditorBackground)
                    .opacity(colorScheme == .dark ? 0.12 : 0.22)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(
                    Color(nsColor: .separatorColor)
                        .opacity(colorScheme == .dark ? 0.58 : 0.46)
                )
                .frame(width: 1)
                .ignoresSafeArea(.container, edges: .vertical)
                .allowsHitTesting(false)
        }
    }
}

private struct RecentFilesView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    @ObservedObject var store: RecentFilesStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("最近文件")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if !store.urls.isEmpty {
                    Text("\(store.urls.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Spacer()
                if !store.urls.isEmpty {
                    Button {
                        windowManager.requestClearRecentFiles()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .stableHelp("清除最近文件")
                }
            }
            .padding(.leading, 13)
            .padding(.trailing, 9)
            .frame(height: 36)

            if store.urls.isEmpty {
                VStack(spacing: 9) {
                    Spacer()
                    Image(systemName: "doc.text")
                        .font(.system(size: 21, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("暂无最近文件")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("打开文件…") {
                        appState.openFiles()
                    }
                    .controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.urls, id: \.self) { url in
                            RecentFileRow(
                                url: url,
                                isOpen: appState.documents.contains {
                                    $0.url?.standardizedFileURL
                                        == url.standardizedFileURL
                                },
                                open: { appState.openFile(url) },
                                openInNewWindow: { windowManager.openFileInNewWindow(url) },
                                showInFinder: {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                },
                                rename: { windowManager.requestRenameFile(url) },
                                remove: { store.remove(url) }
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                }
            }
        }
    }
}

private struct RecentFileRow: View {
    let url: URL
    let isOpen: Bool
    let open: () -> Void
    let openInNewWindow: () -> Void
    let showInFinder: () -> Void
    let rename: () -> Void
    let remove: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Capsule()
                    .fill(isOpen ? Color.accentColor : .clear)
                    .frame(width: 2, height: 17)

                Image(systemName: EditorLanguage.infer(from: url).icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isOpen ? Color.accentColor : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: isOpen ? .medium : .regular))
                        .lineLimit(1)
                    Text(url.deletingLastPathComponent().lastPathComponent)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: LacEditorDesign.sidebarRowHeight)
            .contentShape(Rectangle())
            .background(
                isHovering ? Color.primary.opacity(0.05) : .clear,
                in: RoundedRectangle(
                    cornerRadius: LacEditorDesign.compactCornerRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button {
                open()
            } label: {
                Label("打开", systemImage: "doc.text")
            }

            Button {
                openInNewWindow()
            } label: {
                Label("用新窗口打开", systemImage: "macwindow.badge.plus")
            }

            Divider()

            Button {
                rename()
            } label: {
                Label("重命名…", systemImage: "pencil")
            }

            Button {
                showInFinder()
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }

            Divider()

            Button(role: .destructive) {
                remove()
            } label: {
                Label("从列表中删除", systemImage: "trash")
            }
        }
    }
}
