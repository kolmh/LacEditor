import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false
    @StateObject private var editorSessions = EditorSessionStore(
        limit: 3,
        inactiveMemoryBudget: 64 * 1_024 * 1_024,
        maximumCacheableSessionCost: 24 * 1_024 * 1_024
    )

    var body: some View {
        NativeSidebarSplitView(
            appState: appState,
            windowManager: windowManager,
            sidebar: SidebarView(),
            content: editorWorkspace
        )
        // AppKit owns the titlebar safe area inside the split view. Constraining
        // the entire controller below it prevents full-height sidebar material.
        .ignoresSafeArea(.container, edges: .top)
        .background(Color(nsColor: .lacEditorBackground))
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
            // Keep tabs in the content hierarchy so the editor split reserves
            // their height instead of drawing its divider behind an accessory.
            if showsTabBar {
                TabBarView()
                    .environmentObject(appState)
                    .environmentObject(windowManager)
                    .frame(height: LacEditorDesign.tabBarHeight)
                Divider()
            }

            if let selectedDocument = appState.selectedDocument {
                DocumentEditorPane(
                    document: selectedDocument,
                    sessionStore: editorSessions,
                    fontSize: appState.editorFontSize,
                    lineSpacing: appState.editorLineSpacing,
                    indentationStyle: appState.indentationStyle,
                    tabWidth: appState.tabWidth,
                    wordWrap: selectedDocument.effectiveWordWrap(
                        globalDefault: appState.isWordWrapEnabled
                    ),
                    showsLineNumbers: appState.isLineNumbersVisible,
                    editorTopInset: showsTabBar ? 4 : 0,
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
        .animation(
            reduceMotion ? nil : LacEditorDesign.structuralAnimation,
            value: appState.isStatusBarVisible
        )
    }

    private var showsTabBar: Bool {
        appState.documents.count > 1
    }

}

/// Hosts the editor in AppKit's native sidebar split controller. Keeping the
/// sidebar as a real split-view item avoids the fragile overlay/offset model:
/// AppKit owns divider geometry, collapse behavior and window resizing.
private struct NativeSidebarSplitView: NSViewControllerRepresentable {
    @ObservedObject var appState: AppState
    @ObservedObject var windowManager: WindowManager
    let sidebar: SidebarView
    let content: AnyView

    init(
        appState: AppState,
        windowManager: WindowManager,
        sidebar: SidebarView,
        content: some View
    ) {
        self.appState = appState
        self.windowManager = windowManager
        self.sidebar = sidebar
        self.content = AnyView(content)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller = NSSplitViewController()
        let sidebarController = NSHostingController(
            rootView: AnyView(
                sidebar
                    .environmentObject(appState)
                    .environmentObject(windowManager)
            )
        )
        let contentController = NSHostingController(rootView: content)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.titlebarSeparatorStyle = .none
        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.minimumThickness = 420
        controller.addSplitViewItem(sidebarItem)
        controller.addSplitViewItem(contentItem)
        controller.splitView.dividerStyle = .thin
        controller.splitView.isVertical = true
        controller.view.wantsLayer = true
        controller.view.layer?.backgroundColor = NSColor.lacEditorBackground.cgColor
        DispatchQueue.main.async { [weak controller] in
            guard let controller else { return }
            controller.splitView.setPosition(
                LacEditorDesign.sidebarWidth,
                ofDividerAt: 0
            )
        }

        context.coordinator.sidebarController = sidebarController
        context.coordinator.contentController = contentController
        context.coordinator.sidebarItem = sidebarItem
        context.coordinator.applyCollapseState(
            isVisible: appState.isSidebarVisible
        )
        context.coordinator.observeCollapseState(appState: appState)
        return controller
    }

    func updateNSViewController(
        _ controller: NSSplitViewController,
        context: Context
    ) {
        context.coordinator.sidebarController?.rootView = AnyView(
            sidebar
                .environmentObject(appState)
                .environmentObject(windowManager)
        )
        context.coordinator.contentController?.rootView = content
        context.coordinator.applyCollapseState(
            isVisible: appState.isSidebarVisible
        )
    }

    final class Coordinator {
        var sidebarController: NSHostingController<AnyView>?
        var contentController: NSHostingController<AnyView>?
        weak var sidebarItem: NSSplitViewItem?
        private var collapseObservation: NSKeyValueObservation?
        private var isApplyingCollapseState = false

        func observeCollapseState(appState: AppState) {
            // The system toolbar button changes NSSplitViewItem directly.
            // Reflect that change before SwiftUI next reconciles the layout.
            collapseObservation = sidebarItem?.observe(\.isCollapsed, options: [.new]) {
                [weak self, weak appState] item, _ in
                MainActor.assumeIsolated {
                    guard let self, let appState, !self.isApplyingCollapseState else { return }
                    let isVisible = !item.isCollapsed
                    if appState.isSidebarVisible != isVisible {
                        appState.isSidebarVisible = isVisible
                    }
                }
            }
        }

        func applyCollapseState(isVisible: Bool) {
            guard let sidebarItem else { return }
            if sidebarItem.isCollapsed == !isVisible { return }
            isApplyingCollapseState = true
            sidebarItem.isCollapsed = !isVisible
            isApplyingCollapseState = false
        }
    }

}

private struct DocumentEditorPane: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var document: EditorDocument
    let sessionStore: EditorSessionStore
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let indentationStyle: IndentationStyle
    let tabWidth: Int
    let wordWrap: Bool
    let showsLineNumbers: Bool
    let editorTopInset: CGFloat
    let darkMode: Bool

    var body: some View {
        ZStack {
            HSplitView {
                editor
                    .frame(minWidth: 300)

                if document.isPreviewEffectivelyEnabled {
                    MarkdownPreview(
                        markdown: document.text,
                        revision: document.textRevision,
                        darkMode: darkMode,
                        document: document
                    )
                    .frame(minWidth: 280)
                }
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
            lineSpacing: lineSpacing,
            indentationStyle: indentationStyle,
            tabWidth: tabWidth,
            wordWrap: wordWrap,
            showsLineNumbers: showsLineNumbers,
            topInset: editorTopInset,
            isActive: true,
            requestTextTransformation: appState.presentTextTransformation
        )
    }
}
