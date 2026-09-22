import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    @State private var isSettingsHovering = false

    var body: some View {
        VStack(spacing: 0) {
            SidebarLibraryView(
                recentFiles: appState.recentFiles,
                library: windowManager.sidebarLibrary
            )
            .id(windowManager.primaryReopenGeneration)

            Divider()
                .opacity(0.45)

            Button {
                SettingsWindowController.shared.present(windowManager: windowManager)
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
        .background(SidebarMaterialBackground())
    }
}
