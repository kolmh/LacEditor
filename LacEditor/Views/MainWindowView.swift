import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDropTargeted = false

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                if appState.isSidebarVisible {
                    SidebarView()
                        .frame(width: 252)
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    Divider()
                }

                editorWorkspace
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !appState.isSidebarVisible, appState.isSidebarPreviewVisible {
                SidebarView()
                    .frame(width: 252)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(width: 1)
                    }
                    .onHover(perform: appState.sidebarPreviewHoverChanged)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .animation(.easeOut(duration: 0.18), value: appState.isSidebarVisible)
        .navigationTitle(appState.windowTitle)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            LacEditorToolbar()
        }
        .sheet(isPresented: $appState.isFindReplacePresented) {
            FindReplaceView(state: appState.findReplace)
                .environmentObject(appState)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            var accepted = false
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        url = item as? URL
                    }
                    guard let url, !url.hasDirectoryPath else { return }
                    DispatchQueue.main.async { appState.openFile(url) }
                }
                accepted = true
            }
            return accepted
        }
    }

    @ViewBuilder
    private var editorWorkspace: some View {
        VStack(spacing: 0) {
            TabBarView()
            Divider()
            if let document = appState.selectedDocument {
                if document.language == .markdown && document.isPreviewVisible {
                    HSplitView {
                        EditorTextView(
                            document: document,
                            fontSize: appState.editorFontSize,
                            wordWrap: appState.isWordWrapEnabled,
                            showsLineNumbers: appState.isLineNumbersVisible
                        )
                        .frame(minWidth: 300)

                        MarkdownPreview(
                            markdown: document.text,
                            darkMode: colorScheme == .dark
                        )
                        .frame(minWidth: 280)
                    }
                } else {
                    EditorTextView(
                        document: document,
                        fontSize: appState.editorFontSize,
                        wordWrap: appState.isWordWrapEnabled,
                        showsLineNumbers: appState.isLineNumbersVisible
                    )
                }
                if appState.isStatusBarVisible {
                    Divider()
                    StatusBarView(document: document)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: appState.isStatusBarVisible)
    }
}
