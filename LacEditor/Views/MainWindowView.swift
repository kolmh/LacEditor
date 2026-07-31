import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDropTargeted = false
    @State private var loadedDocumentIDs: [UUID] = []
    private let editorCacheLimit = 8

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
        .navigationTitle(appState.windowTitle)
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
        .onAppear {
            if let selectedID = appState.selectedDocumentID {
                markEditorLoaded(selectedID)
            }
        }
        .onChange(of: appState.selectedDocumentID) { _, selectedID in
            if let selectedID {
                markEditorLoaded(selectedID)
            }
        }
        .onChange(of: appState.documents.map(\.id)) { _, documentIDs in
            let liveIDs = Set(documentIDs)
            loadedDocumentIDs.removeAll { !liveIDs.contains($0) }
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
                ZStack {
                    ForEach(loadedDocuments) { document in
                        DocumentEditorPane(
                            document: document,
                            isActive: document.id == selectedDocument.id,
                            fontSize: appState.editorFontSize,
                            wordWrap: appState.isWordWrapEnabled,
                            showsLineNumbers: appState.isLineNumbersVisible,
                            darkMode: colorScheme == .dark
                        )
                        .opacity(document.id == selectedDocument.id ? 1 : 0)
                        .allowsHitTesting(document.id == selectedDocument.id)
                        .accessibilityHidden(document.id != selectedDocument.id)
                        .zIndex(document.id == selectedDocument.id ? 1 : 0)
                    }
                }
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

    private var loadedDocuments: [EditorDocument] {
        appState.documents.filter {
            loadedDocumentIDs.contains($0.id) || $0.id == appState.selectedDocumentID
        }
    }

    private func markEditorLoaded(_ documentID: UUID) {
        loadedDocumentIDs.removeAll { $0 == documentID }
        loadedDocumentIDs.append(documentID)
        if loadedDocumentIDs.count > editorCacheLimit {
            loadedDocumentIDs.removeFirst(
                loadedDocumentIDs.count - editorCacheLimit
            )
        }
    }
}

private struct DocumentEditorPane: View {
    @ObservedObject var document: EditorDocument
    let isActive: Bool
    let fontSize: CGFloat
    let wordWrap: Bool
    let showsLineNumbers: Bool
    let darkMode: Bool

    var body: some View {
        Group {
            if document.language == .markdown && document.isPreviewVisible {
                HSplitView {
                    editor
                        .frame(minWidth: 300)

                    MarkdownPreview(
                        markdown: document.text,
                        darkMode: darkMode
                    )
                    .frame(minWidth: 280)
                }
            } else {
                editor
            }
        }
    }

    private var editor: some View {
        EditorTextView(
            document: document,
            fontSize: fontSize,
            wordWrap: wordWrap,
            showsLineNumbers: showsLineNumbers,
            isActive: isActive
        )
    }
}
