import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDropTargeted = false
    @StateObject private var editorSessions = EditorSessionStore(
        limit: 3,
        inactiveMemoryBudget: 64 * 1_024 * 1_024,
        maximumCacheableSessionCost: 24 * 1_024 * 1_024
    )

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                if appState.isSidebarVisible {
                    SidebarView()
                        .frame(width: 252)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                editorWorkspace
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !appState.isSidebarVisible, appState.isSidebarPreviewVisible {
                SidebarView()
                    .frame(width: 252)
                    .onHover(perform: appState.sidebarPreviewHoverChanged)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .animation(.easeOut(duration: 0.18), value: appState.isSidebarVisible)
        .background(Color(nsColor: .lacEditorBackground))
        .toolbar {
            LacEditorToolbar()
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
        .onChange(of: appState.documents.map(\.id)) { _, documentIDs in
            editorSessions.retainDocuments(Set(documentIDs))
        }
    }

    @ViewBuilder
    private var editorWorkspace: some View {
        VStack(spacing: 0) {
            if showsTabBar {
                VStack(spacing: 0) {
                    TabBarView()
                    Divider()
                }
                .transition(
                    .move(edge: .top)
                        .combined(with: .opacity)
                )
            }
            if let selectedDocument = appState.selectedDocument {
                DocumentEditorPane(
                    document: selectedDocument,
                    sessionStore: editorSessions,
                    fontSize: appState.editorFontSize,
                    wordWrap: selectedDocument.effectiveWordWrap(
                        globalDefault: appState.isWordWrapEnabled
                    ),
                    showsLineNumbers: appState.isLineNumbersVisible,
                    editorTopInset: showsTabBar ? 6 : 0,
                    darkMode: colorScheme == .dark
                )
                .id(selectedDocument.id)
                .animation(nil, value: appState.selectedDocumentID)

                if appState.isStatusBarVisible {
                    Divider()
                    StatusBarView(document: selectedDocument)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.16), value: showsTabBar)
        .animation(.easeInOut(duration: 0.18), value: appState.isStatusBarVisible)
    }

    private var showsTabBar: Bool {
        appState.documents.count > 1
    }

}

private struct DocumentEditorPane: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var document: EditorDocument
    let sessionStore: EditorSessionStore
    let fontSize: CGFloat
    let wordWrap: Bool
    let showsLineNumbers: Bool
    let editorTopInset: CGFloat
    let darkMode: Bool

    var body: some View {
        ZStack {
            if document.isPreviewEffectivelyEnabled {
                HSplitView {
                    editor
                        .frame(minWidth: 300)

                    MarkdownPreview(
                        markdown: document.text,
                        darkMode: darkMode,
                        document: document
                    )
                    .frame(minWidth: 280)
                }
            } else {
                editor
            }
            if document.ioState == .opening {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在打开“\(document.displayName)”")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("取消") {
                        appState.cancelOpening(document)
                    }
                }
            }
        }
    }

    private var editor: some View {
        EditorTextView(
            document: document,
            sessionStore: sessionStore,
            fontSize: fontSize,
            wordWrap: wordWrap,
            showsLineNumbers: showsLineNumbers,
            topInset: editorTopInset,
            isActive: true
        )
    }
}
