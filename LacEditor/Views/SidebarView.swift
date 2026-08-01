import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            RecentFilesView(store: appState.recentFiles)

            Divider()

            Button {
                openSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .stableHelp("打开设置", shortcut: "⌘,")
            .padding(.horizontal, 14)
            .frame(height: 40)
        }
        .background {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                Color(nsColor: .lacEditorBackground)
                    .opacity(colorScheme == .dark ? 0.18 : 0.42)
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
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Text("最近文件")
                    .font(.system(size: 13, weight: .semibold))
                if !store.urls.isEmpty {
                    Text("\(store.urls.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if !store.urls.isEmpty {
                    Button {
                        windowManager.requestClearRecentFiles()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .stableHelp("清除最近文件")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)

            if store.urls.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "clock")
                        .font(.system(size: 24, weight: .light))
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
                    .padding(.horizontal, 7)
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

private struct RecentFileRow: View {
    let url: URL
    let open: () -> Void
    let openInNewWindow: () -> Void
    let showInFinder: () -> Void
    let rename: () -> Void
    let remove: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                Image(systemName: EditorLanguage.infer(from: url).icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor.opacity(0.9))
                    .frame(width: 17)

                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(url.deletingLastPathComponent().lastPathComponent)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .contentShape(Rectangle())
            .background(
                isHovering ? Color.primary.opacity(0.055) : .clear,
                in: RoundedRectangle(cornerRadius: 4)
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
