import AppKit

/// Owns the editor window's toolbar as a native AppKit toolbar. Keeping all
/// titlebar controls in one toolbar lets macOS provide a single active/inactive
/// surface and align the sidebar boundary with the split view divider.
@MainActor
final class EditorWindowToolbarController: NSObject, NSToolbarDelegate {
    private enum ItemIdentifier {
        static let title = NSToolbarItem.Identifier("LacEditor.WindowTitle")
        static let history = NSToolbarItem.Identifier("LacEditor.History")
        static let language = NSToolbarItem.Identifier("LacEditor.Language")
        static let preview = NSToolbarItem.Identifier("LacEditor.Preview")
    }

    private weak var appState: AppState?
    private let titleField = NSTextField(labelWithString: "LacEditor")
    private let languageButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private weak var sidebarItem: NSToolbarItem?
    private weak var historyItem: NSToolbarItemGroup?
    private weak var previewItem: NSToolbarItem?

    init(appState: AppState) {
        self.appState = appState
        super.init()
        configureTitleField()
        configureLanguageButton()
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = EditorWindowToolbar(
            identifier: NSToolbar.Identifier("LacEditor.EditorToolbar")
        )
        toolbar.controller = self
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .regular
        update()
        return toolbar
    }

    func update(appState: AppState? = nil) {
        if let appState {
            self.appState = appState
        }
        guard let appState else { return }

        titleField.stringValue = appState.windowTitle
        sidebarItem?.toolTip = appState.isSidebarVisible
            ? "隐藏侧边栏（⌃⌘B）"
            : "显示侧边栏（⌃⌘B）"

        guard let document = appState.selectedDocument else {
            historyItem?.isEnabled = false
            languageButton.isEnabled = false
            previewItem?.isEnabled = false
            return
        }

        historyItem?.isEnabled = true
        languageButton.isEnabled = true
        if let index = EditorLanguage.allCases.firstIndex(of: document.language) {
            languageButton.selectItem(at: index)
        }
        updateLanguageButton(for: document.language)

        previewItem?.isEnabled = document.language == .markdown
        previewItem?.image = NSImage(
            systemSymbolName: document.isPreviewEffectivelyEnabled
                ? "rectangle.split.2x1.fill"
                : "rectangle.split.2x1",
            accessibilityDescription: document.isPreviewEffectivelyEnabled
                ? "隐藏 Markdown 预览"
                : "显示 Markdown 预览"
        )
        previewItem?.toolTip = document.isPreviewEffectivelyEnabled
            ? "隐藏 Markdown 预览（⌥⌘P）"
            : "显示 Markdown 预览（⌥⌘P）"
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            ItemIdentifier.title,
            .flexibleSpace,
            ItemIdentifier.history,
            ItemIdentifier.language,
            ItemIdentifier.preview
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleSidebar:
            return makeSidebarItem()
        case ItemIdentifier.title:
            return makeTitleItem()
        case ItemIdentifier.history:
            return makeHistoryItem()
        case ItemIdentifier.language:
            return makeLanguageItem()
        case ItemIdentifier.preview:
            return makePreviewItem()
        default:
            // AppKit supplies flexible space and the sidebar tracking
            // separator. The latter discovers the native split view and keeps
            // the toolbar boundary aligned while the sidebar is resized.
            return nil
        }
    }

    private func makeSidebarItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .toggleSidebar)
        item.label = "侧边栏"
        item.paletteLabel = "侧边栏"
        item.image = NSImage(
            systemSymbolName: "sidebar.left",
            accessibilityDescription: "切换侧边栏"
        )
        item.target = self
        item.action = #selector(toggleSidebar)
        item.isNavigational = true
        sidebarItem = item
        return item
    }

    private func makeTitleItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemIdentifier.title)
        item.label = "文档标题"
        item.view = titleField
        item.visibilityPriority = .high
        return item
    }

    private func makeHistoryItem() -> NSToolbarItem {
        let undoImage = NSImage(
            systemSymbolName: "arrow.uturn.backward",
            accessibilityDescription: "撤销"
        ) ?? NSImage()
        let redoImage = NSImage(
            systemSymbolName: "arrow.uturn.forward",
            accessibilityDescription: "重做"
        ) ?? NSImage()
        let undoItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("LacEditor.Undo"))
        undoItem.label = "撤销"
        undoItem.image = undoImage
        undoItem.target = self
        undoItem.action = #selector(performUndo)
        undoItem.toolTip = "撤销（⌘Z）"

        let redoItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("LacEditor.Redo"))
        redoItem.label = "重做"
        redoItem.image = redoImage
        redoItem.target = self
        redoItem.action = #selector(performRedo)
        redoItem.toolTip = "重做（⇧⌘Z）"

        let item = NSToolbarItemGroup(itemIdentifier: ItemIdentifier.history)
        item.subitems = [undoItem, redoItem]
        item.label = "编辑历史"
        item.controlRepresentation = .expanded
        historyItem = item
        return item
    }

    private func makeLanguageItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemIdentifier.language)
        item.label = "语言模式"
        item.view = languageButton
        item.visibilityPriority = .high
        return item
    }

    private func makePreviewItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemIdentifier.preview)
        item.label = "Markdown 预览"
        item.image = NSImage(
            systemSymbolName: "rectangle.split.2x1",
            accessibilityDescription: "切换 Markdown 预览"
        )
        item.target = self
        item.action = #selector(togglePreview)
        previewItem = item
        return item
    }

    private func configureTitleField() {
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1
        titleField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            titleField.widthAnchor.constraint(lessThanOrEqualToConstant: 260)
        ])
    }

    private func configureLanguageButton() {
        languageButton.bezelStyle = .toolbar
        languageButton.controlSize = .regular
        languageButton.font = .systemFont(ofSize: 12)
        languageButton.imagePosition = .imageLeading
        languageButton.target = self
        languageButton.action = #selector(selectLanguage(_:))
        languageButton.toolTip = "语言模式"
        languageButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            languageButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 122),
            languageButton.heightAnchor.constraint(equalToConstant: 28)
        ])

        for language in EditorLanguage.allCases {
            let item = NSMenuItem(title: language.displayName, action: nil, keyEquivalent: "")
            item.image = NSImage(
                systemSymbolName: language.icon,
                accessibilityDescription: language.displayName
            )
            languageButton.menu?.addItem(item)
        }
    }

    private func updateLanguageButton(for language: EditorLanguage) {
        languageButton.image = NSImage(
            systemSymbolName: language.icon,
            accessibilityDescription: language.displayName
        )
        languageButton.setAccessibilityLabel("语言模式：\(language.displayName)")
    }

    @objc private func toggleSidebar() {
        appState?.toggleSidebar()
    }

    @objc private func performUndo() {
        guard let documentID = appState?.selectedDocument?.id else { return }
        NotificationCenter.default.post(
            name: EditorCommandNotification.undo,
            object: documentID
        )
    }

    @objc private func performRedo() {
        guard let documentID = appState?.selectedDocument?.id else { return }
        NotificationCenter.default.post(
            name: EditorCommandNotification.redo,
            object: documentID
        )
    }

    @objc private func selectLanguage(_ sender: NSPopUpButton) {
        guard EditorLanguage.allCases.indices.contains(sender.indexOfSelectedItem) else {
            return
        }
        appState?.setLanguage(EditorLanguage.allCases[sender.indexOfSelectedItem])
        update()
    }

    @objc private func togglePreview() {
        appState?.togglePreview()
        update()
    }
}

private final class EditorWindowToolbar: NSToolbar {
    var controller: EditorWindowToolbarController?
}

@MainActor
func configureEditorWindowToolbar(_ window: NSWindow, appState: AppState) {
    if let toolbar = window.toolbar as? EditorWindowToolbar,
       let controller = toolbar.controller {
        controller.update(appState: appState)
        localizeNativeToolbarItems(in: toolbar)
        return
    }

    let controller = EditorWindowToolbarController(appState: appState)
    let toolbar = controller.makeToolbar()
    window.toolbar = toolbar
    // AppKit may materialize the system items one run-loop turn after the
    // toolbar is assigned. Normalize them again after that materialization so
    // the accessibility label and tooltip never fall back to English.
    DispatchQueue.main.async {
        localizeNativeToolbarItems(in: toolbar)
    }
}

@MainActor
private func localizeNativeToolbarItems(in toolbar: NSToolbar) {
    for item in toolbar.items {
        guard item.itemIdentifier == .toggleSidebar else { continue }
        item.label = "侧边栏"
        item.paletteLabel = "侧边栏"
        item.toolTip = "显示或隐藏侧边栏（⌃⌘B）"
        item.view?.setAccessibilityLabel("侧边栏")
        item.view?.setAccessibilityHelp("显示或隐藏侧边栏")
    }
}
