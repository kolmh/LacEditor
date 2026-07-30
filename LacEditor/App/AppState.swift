import AppKit
import Combine
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum EditorCommandNotification {
    static let revealSelection = Notification.Name("LacEditor.revealSelection")
    static let toggleFold = Notification.Name("LacEditor.toggleFold")
    static let undo = Notification.Name("LacEditor.undo")
    static let redo = Notification.Name("LacEditor.redo")
}

struct EditorSelectionRequest {
    let documentID: UUID
    let range: NSRange
}

@MainActor
final class AppState: ObservableObject {
    @Published var documents: [EditorDocument] = []
    @Published var selectedDocumentID: UUID?
    @Published var isSidebarVisible = true
    @Published private(set) var isSidebarPreviewVisible = false
    @Published var workspaceURL: URL?
    @Published var fileTree: [FileTreeNode] = []
    @Published var isWordWrapEnabled = true
    @Published var editorFontSize: CGFloat = 14
    @Published var isFindReplacePresented = false
    @Published var isLineNumbersVisible: Bool {
        didSet {
            UserDefaults.standard.set(
                isLineNumbersVisible,
                forKey: "isLineNumbersVisible"
            )
        }
    }
    @Published var isStatusBarVisible: Bool {
        didSet {
            UserDefaults.standard.set(
                isStatusBarVisible,
                forKey: "isStatusBarVisible"
            )
        }
    }
    @Published var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "appTheme") }
    }

    let recentFiles: RecentFilesStore
    let findReplace = FindReplaceState()
    weak var hostWindow: NSWindow?
    private let fileService = FileService()
    private var documentCancellables: [UUID: AnyCancellable] = [:]
    private var sidebarPreviewDismissWorkItem: DispatchWorkItem?
    private let defaultFontSize: CGFloat = 14

    init(
        initialDocument: EditorDocument? = nil,
        recentFiles: RecentFilesStore
    ) {
        self.recentFiles = recentFiles
        isLineNumbersVisible = UserDefaults.standard.object(
            forKey: "isLineNumbersVisible"
        ) as? Bool ?? true
        isStatusBarVisible = UserDefaults.standard.object(
            forKey: "isStatusBarVisible"
        ) as? Bool ?? true
        let storedTheme = UserDefaults.standard.string(forKey: "appTheme")
        theme = AppTheme(rawValue: storedTheme ?? "") ?? .system
        if let initialDocument {
            documents = [initialDocument]
            selectedDocumentID = initialDocument.id
            observe(initialDocument)
        } else {
            newDocument()
        }
    }

    var selectedDocument: EditorDocument? {
        guard let selectedDocumentID else { return nil }
        return documents.first { $0.id == selectedDocumentID }
    }

    var selectedDocumentIndex: Int? {
        guard let selectedDocumentID else { return nil }
        return documents.firstIndex { $0.id == selectedDocumentID }
    }

    var preferredColorScheme: ColorScheme {
        switch theme {
        case .system:
            let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? .dark : .light
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    func refreshSystemAppearance() {
        guard theme == .system else { return }
        objectWillChange.send()
    }

    var windowTitle: String {
        guard let document = selectedDocument else { return "LacEditor" }
        return "\(document.isDirty ? "● " : "")\(document.displayName) — LacEditor"
    }

    func toggleSidebar() {
        sidebarPreviewDismissWorkItem?.cancel()
        isSidebarVisible.toggle()
        isSidebarPreviewVisible = false
    }

    func sidebarPreviewHoverChanged(_ isHovering: Bool) {
        guard !isSidebarVisible else {
            isSidebarPreviewVisible = false
            return
        }

        sidebarPreviewDismissWorkItem?.cancel()
        if isHovering {
            withAnimation(.easeOut(duration: 0.16)) {
                isSidebarPreviewVisible = true
            }
        } else {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, !self.isSidebarVisible else { return }
                withAnimation(.easeOut(duration: 0.14)) {
                    self.isSidebarPreviewVisible = false
                }
            }
            sidebarPreviewDismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
        }
    }

    func newDocument() {
        let document = EditorDocument()
        documents.append(document)
        selectedDocumentID = document.id
        observe(document)
    }

    func openFiles() {
        fileService.chooseFiles().forEach(openFile)
    }

    func openFile(_ url: URL) {
        let normalized = url.standardizedFileURL
        if let existing = documents.first(where: {
            $0.url?.standardizedFileURL == normalized
        }) {
            selectedDocumentID = existing.id
            return
        }

        do {
            let decoded = try fileService.read(normalized)
            let language = EditorLanguage.infer(from: normalized)
            let document = EditorDocument(
                text: decoded.text,
                url: normalized,
                language: language,
                encodingName: decoded.encodingName
            )
            if documents.count == 1,
               let first = documents.first,
               first.url == nil,
               first.text.isEmpty,
               !first.isDirty {
                stopObserving(first)
                documents.removeAll()
            }
            documents.append(document)
            selectedDocumentID = document.id
            recentFiles.record(normalized)
            observe(document)
        } catch CocoaError.userCancelled {
            return
        } catch {
            presentError(title: "无法打开文件", error: error)
        }
    }

    func openFolder() {
        guard let url = fileService.chooseFolder() else { return }
        workspaceURL = url
        fileTree = fileService.loadTree(at: url)
    }

    @discardableResult
    func save(_ document: EditorDocument? = nil) -> Bool {
        guard let document = document ?? selectedDocument else { return false }
        if let url = document.url {
            return write(document, to: url)
        }
        return saveAs(document)
    }

    @discardableResult
    func saveAs(_ document: EditorDocument? = nil) -> Bool {
        guard let document = document ?? selectedDocument,
              let url = fileService.chooseSaveURL(suggestedName: suggestedFilename(for: document))
        else { return false }
        return write(document, to: url)
    }

    func closeSelectedDocument() {
        guard let document = selectedDocument else { return }
        close(document)
    }

    func close(_ document: EditorDocument) {
        if documents.count == 1, document.isDisposableBlank {
            hostWindow?.performClose(nil)
            return
        }
        guard confirmClosing(document) else { return }
        removeDocument(document)
    }

    func closeOtherDocuments(keeping document: EditorDocument) {
        let others = documents.filter { $0.id != document.id }
        guard others.allSatisfy(confirmClosing) else { return }
        others.forEach(stopObserving)
        documents = [document]
        selectedDocumentID = document.id
    }

    func closeDocumentsToRight(of document: EditorDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }),
              index + 1 < documents.count else { return }
        let right = Array(documents[(index + 1)...])
        guard right.allSatisfy(confirmClosing) else { return }
        right.forEach(stopObserving)
        documents.removeSubrange((index + 1)...)
        selectedDocumentID = document.id
    }

    func selectNextTab() {
        guard !documents.isEmpty else { return }
        let index = selectedDocumentIndex ?? 0
        selectedDocumentID = documents[(index + 1) % documents.count].id
    }

    func selectPreviousTab() {
        guard !documents.isEmpty else { return }
        let index = selectedDocumentIndex ?? 0
        selectedDocumentID = documents[(index - 1 + documents.count) % documents.count].id
    }

    func selectTab(at index: Int) {
        guard documents.indices.contains(index) else { return }
        selectedDocumentID = documents[index].id
    }

    func moveDocument(_ sourceID: UUID, relativeTo targetID: UUID) {
        guard sourceID != targetID,
              let sourceIndex = documents.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = documents.firstIndex(where: { $0.id == targetID })
        else { return }

        let destination = sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        documents.move(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: destination
        )
    }

    func takeDocumentForTransfer(_ document: EditorDocument) -> EditorDocument? {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else {
            return nil
        }
        stopObserving(document)
        documents.remove(at: index)
        if documents.isEmpty {
            newDocument()
        } else {
            selectedDocumentID = documents[min(index, documents.count - 1)].id
        }
        return document
    }

    func togglePreview() {
        guard let document = selectedDocument, document.language == .markdown else { return }
        document.isPreviewVisible.toggle()
    }

    func setLanguage(_ language: EditorLanguage) {
        guard let document = selectedDocument else { return }
        let wasMarkdown = document.language == .markdown
        document.language = language
        if language == .markdown && !wasMarkdown {
            document.isPreviewVisible = true
        } else if language != .markdown {
            document.isPreviewVisible = false
        }
    }

    func formatJSON(pretty: Bool = true) {
        guard let document = selectedDocument, document.language == .json else { return }
        do {
            document.text = try JSONFormatter.format(document.text, pretty: pretty)
            document.refreshDirtyState()
            document.statusMessage = pretty ? "JSON 已格式化" : "JSON 已压缩"
        } catch {
            document.statusMessage = JSONFormatter.userFacingError(error, in: document.text)
        }
    }

    func presentFindReplace(mode: FindReplaceMode) {
        findReplace.mode = mode
        findReplace.message = nil
        isFindReplacePresented = true
    }

    func findNext() {
        guard let document = selectedDocument else { return }
        let query = interpretedSearchQuery()
        guard !query.isEmpty else {
            presentFindReplace(mode: .find)
            return
        }
        guard let range = TextSearchService.nextRange(
            in: document.text,
            query: query,
            after: document.selectionRange,
            caseSensitive: findReplace.isCaseSensitive
        ) else {
            findReplace.message = "未找到匹配内容"
            return
        }
        reveal(range, in: document)
        findReplace.message = "已找到匹配内容"
    }

    func findPrevious() {
        guard let document = selectedDocument else { return }
        let query = interpretedSearchQuery()
        guard !query.isEmpty else {
            presentFindReplace(mode: .find)
            return
        }
        guard let range = TextSearchService.previousRange(
            in: document.text,
            query: query,
            before: document.selectionRange,
            caseSensitive: findReplace.isCaseSensitive
        ) else {
            findReplace.message = "未找到匹配内容"
            return
        }
        reveal(range, in: document)
        findReplace.message = "已找到匹配内容"
    }

    func replaceCurrentMatch() {
        guard let document = selectedDocument else { return }
        let query = interpretedSearchQuery()
        guard !query.isEmpty else {
            findReplace.message = "请输入查找内容"
            return
        }
        guard TextSearchService.selectionMatches(
            in: document.text,
            query: query,
            selection: document.selectionRange,
            caseSensitive: findReplace.isCaseSensitive
        ) else {
            findNext()
            return
        }

        let replacement = TextSearchService.interpreted(
            findReplace.replacement,
            enabled: findReplace.interpretsEscapes
        )
        let mutable = NSMutableString(string: document.text)
        let originalRange = document.selectionRange
        mutable.replaceCharacters(in: originalRange, with: replacement)
        document.text = mutable as String
        document.refreshDirtyState()
        let nextSelection = NSRange(
            location: originalRange.location,
            length: (replacement as NSString).length
        )
        reveal(nextSelection, in: document)
        findReplace.message = "已替换 1 处"
    }

    func replaceAllMatches() {
        guard let document = selectedDocument else { return }
        let query = interpretedSearchQuery()
        guard !query.isEmpty else {
            findReplace.message = "请输入查找内容"
            return
        }
        let replacement = TextSearchService.interpreted(
            findReplace.replacement,
            enabled: findReplace.interpretsEscapes
        )
        let result = TextSearchService.replacingAll(
            in: document.text,
            query: query,
            replacement: replacement,
            caseSensitive: findReplace.isCaseSensitive
        )
        guard result.count > 0 else {
            findReplace.message = "未找到匹配内容"
            return
        }
        document.text = result.text
        document.refreshDirtyState()
        reveal(NSRange(location: 0, length: 0), in: document)
        findReplace.message = "已替换 \(result.count) 处"
    }

    func increaseFontSize() {
        editorFontSize = min(editorFontSize + 1, 32)
    }

    func decreaseFontSize() {
        editorFontSize = max(editorFontSize - 1, 9)
    }

    func resetFontSize() {
        editorFontSize = defaultFontSize
    }

    func renameFile(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "重命名文件"
        alert.informativeText = "请输入新的文件名。"
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")

        let nameField = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 320, height: 24)
        )
        nameField.stringValue = url.lastPathComponent
        nameField.selectText(nil)
        alert.accessoryView = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = nameField.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        do {
            let newURL = try fileService.rename(url, to: newName)
            for document in documents
            where document.url?.standardizedFileURL == url.standardizedFileURL {
                let wasMarkdown = document.language == .markdown
                let language = EditorLanguage.infer(from: newURL)
                document.url = newURL
                document.language = language
                if language == .markdown, !wasMarkdown {
                    document.isPreviewVisible = true
                } else if language != .markdown {
                    document.isPreviewVisible = false
                }
            }
            recentFiles.replace(url, with: newURL)
        } catch {
            presentError(title: "无法重命名文件", error: error)
        }
    }

    func confirmClosingAllDocuments() -> Bool {
        documents.allSatisfy(confirmClosing)
    }

    private func observe(_ document: EditorDocument) {
        documentCancellables[document.id] = document.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
    }

    private func stopObserving(_ document: EditorDocument) {
        documentCancellables.removeValue(forKey: document.id)?.cancel()
    }

    private func suggestedFilename(for document: EditorDocument) -> String {
        if let existing = document.url?.lastPathComponent { return existing }
        return switch document.language {
        case .markdown: "未命名.md"
        case .json: "未命名.json"
        case .html: "未命名.html"
        case .javascript: "未命名.js"
        case .typescript: "未命名.ts"
        case .css: "未命名.css"
        case .python: "未命名.py"
        case .swift: "未命名.swift"
        case .shell: "未命名.sh"
        case .yaml: "未命名.yaml"
        case .cFamily: "未命名.cpp"
        case .sql: "未命名.sql"
        case .plainText: "未命名.txt"
        }
    }

    private func interpretedSearchQuery() -> String {
        TextSearchService.interpreted(
            findReplace.query,
            enabled: findReplace.interpretsEscapes
        )
    }

    private func reveal(_ range: NSRange, in document: EditorDocument) {
        document.selectionRange = range
        NotificationCenter.default.post(
            name: EditorCommandNotification.revealSelection,
            object: EditorSelectionRequest(documentID: document.id, range: range)
        )
    }

    private func write(_ document: EditorDocument, to url: URL) -> Bool {
        do {
            try fileService.write(document.text, to: url)
            document.url = url.standardizedFileURL
            document.language = EditorLanguage.infer(from: url)
            document.encodingName = "UTF-8"
            document.markSaved()
            document.statusMessage = "已保存"
            recentFiles.record(url)
            return true
        } catch {
            presentError(title: "无法保存文件", error: error)
            return false
        }
    }

    private func confirmClosing(_ document: EditorDocument) -> Bool {
        document.refreshDirtyState()
        guard document.isDirty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "要保存对“\(document.displayName)”的更改吗？"
        alert.informativeText = "如果不保存，更改将会丢失。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return save(document)
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func removeDocument(_ document: EditorDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        stopObserving(document)
        documents.remove(at: index)
        if documents.isEmpty {
            newDocument()
        } else {
            selectedDocumentID = documents[min(index, documents.count - 1)].id
        }
    }

    private func presentError(title: String, error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.runModal()
    }
}
