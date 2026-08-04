import AppKit
import Combine
import os
import SwiftUI

private let filePerformanceLog = OSLog(
    subsystem: "com.laceditor.LacEditor",
    category: "FilePerformance"
)

private let taskPerformanceLog = OSLog(
    subsystem: "com.laceditor.LacEditor",
    category: "DocumentTasks"
)

private func documentTaskSignpostName(
    for kind: DocumentTaskCoordinator.Kind
) -> StaticString {
    switch kind {
    case .search: "Search"
    case .replace: "ReplaceAll"
    case .json: "JSONFormat"
    case .preview: "MarkdownRender"
    case .metrics: "Metrics"
    case .save: "FileSave"
    case .listNormalization: "ListNormalization"
    case .delimiterMatch: "DelimiterMatch"
    }
}

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
    static let applyTextUpdate = Notification.Name("LacEditor.applyTextUpdate")
    static let documentContentDidChange = Notification.Name(
        "LacEditor.documentContentDidChange"
    )
}

struct EditorSelectionRequest {
    let documentID: UUID
    let range: NSRange
}

final class EditorTextUpdateRequest {
    let documentID: UUID
    let text: String
    let selectionRange: NSRange
    let actionName: String
    var wasHandled = false

    init(
        documentID: UUID,
        text: String,
        selectionRange: NSRange,
        actionName: String
    ) {
        self.documentID = documentID
        self.text = text
        self.selectionRange = selectionRange
        self.actionName = actionName
    }
}

enum SidebarPresentation: Equatable {
    case hidden
    case preview
    case pinned
}

@MainActor
final class AppState: ObservableObject {
    @Published var documents: [EditorDocument] = []
    @Published var selectedDocumentID: UUID?
    @Published var isSidebarVisible: Bool {
        didSet {
            UserDefaults.standard.set(
                isSidebarVisible,
                forKey: "isSidebarVisible"
            )
        }
    }
    @Published private(set) var isSidebarPreviewVisible = false
    private var isSidebarToggleHovered = false
    private var isSidebarPreviewHovered = false
    @Published var workspaceURL: URL?
    @Published var fileTree: [FileTreeNode] = []
    @Published var isWordWrapEnabled = true
    @Published var editorFontSize: CGFloat = 14 {
        didSet {
            UserDefaults.standard.set(
                Double(editorFontSize),
                forKey: "editorFontSize"
            )
        }
    }
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
    private var findReplaceWindowController: FindReplaceWindowController?
    private let fileService = FileService()
    private let fileReadQueue = DispatchQueue(
        label: "com.laceditor.file-reading",
        qos: .userInitiated
    )
    private let fileWriteQueue = DispatchQueue(
        label: "com.laceditor.file-writing",
        qos: .userInitiated
    )
    private let documentTaskQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.laceditor.document-tasks"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var documentCancellables: [UUID: AnyCancellable] = [:]
    private var openingFileURLs: Set<URL> = []
    private var cancelledOpeningURLs: Set<URL> = []
    private var sidebarPreviewDismissWorkItem: DispatchWorkItem?
    private let defaultFontSize: CGFloat = 14
    private var contentChangeObserver: NSObjectProtocol?

    init(
        initialDocument: EditorDocument? = nil,
        recentFiles: RecentFilesStore
    ) {
        self.recentFiles = recentFiles
        let storedFontSize = UserDefaults.standard.object(
            forKey: "editorFontSize"
        ) as? Double
        editorFontSize = min(max(CGFloat(storedFontSize ?? 14), 9), 32)
        isSidebarVisible = UserDefaults.standard.object(
            forKey: "isSidebarVisible"
        ) as? Bool ?? true
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
        contentChangeObserver = NotificationCenter.default.addObserver(
            forName: EditorCommandNotification.documentContentDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let documentID = notification.object as? UUID,
                      let document = self.documents.first(where: { $0.id == documentID }) else { return }
                document.taskCoordinator.cancel(.search)
                document.taskCoordinator.cancel(.replace)
                document.taskCoordinator.cancel(.json)
                document.taskCoordinator.cancel(.listNormalization)
                if document.statusMessage?.hasPrefix("正在格式化") == true
                    || document.statusMessage?.hasPrefix("正在压缩") == true {
                    document.statusMessage = "内容已变化，JSON 操作已取消"
                }
                if self.findReplace.isWorking {
                    self.findReplace.isWorking = false
                    self.findReplace.message = "内容已变化，任务已取消"
                }
            }
        }
    }

    deinit {
        if let contentChangeObserver {
            NotificationCenter.default.removeObserver(contentChangeObserver)
        }
        documentTaskQueue.cancelAllOperations()
    }

    var selectedDocument: EditorDocument? {
        guard let selectedDocumentID else { return nil }
        return documents.first { $0.id == selectedDocumentID }
    }

    var selectedDocumentIndex: Int? {
        guard let selectedDocumentID else { return nil }
        return documents.firstIndex { $0.id == selectedDocumentID }
    }

    var hasPendingSave: Bool {
        documents.contains { $0.ioState == .saving }
    }

    func waitForPendingSaves(completion: @escaping () -> Void) {
        guard hasPendingSave else {
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.waitForPendingSaves(completion: completion)
        }
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

    var sidebarPresentation: SidebarPresentation {
        if isSidebarVisible { return .pinned }
        if isSidebarPreviewVisible { return .preview }
        return .hidden
    }

    func toggleSidebar() {
        sidebarPreviewDismissWorkItem?.cancel()
        sidebarPreviewDismissWorkItem = nil
        isSidebarPreviewHovered = false
        if isSidebarPreviewVisible {
            isSidebarVisible = true
            isSidebarPreviewVisible = false
            return
        }
        isSidebarVisible.toggle()
        isSidebarPreviewVisible = false
    }

    func sidebarToggleHoverChanged(_ isHovering: Bool) {
        isSidebarToggleHovered = isHovering
        guard !isSidebarVisible else {
            isSidebarPreviewVisible = false
            return
        }

        sidebarPreviewDismissWorkItem?.cancel()
        sidebarPreviewDismissWorkItem = nil
        if isHovering {
            withAnimation(.easeOut(duration: 0.16)) {
                isSidebarPreviewVisible = true
            }
        } else if !isSidebarPreviewHovered {
            scheduleSidebarPreviewDismissal()
        }
    }

    func sidebarPreviewHoverChanged(_ isHovering: Bool) {
        guard !isSidebarVisible, isSidebarPreviewVisible else {
            isSidebarPreviewHovered = false
            return
        }
        isSidebarPreviewHovered = isHovering

        sidebarPreviewDismissWorkItem?.cancel()
        sidebarPreviewDismissWorkItem = nil
        if !isHovering, !isSidebarToggleHovered {
            scheduleSidebarPreviewDismissal()
        }
    }

    private func scheduleSidebarPreviewDismissal() {
        sidebarPreviewDismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.isSidebarVisible,
                  !self.isSidebarToggleHovered,
                  !self.isSidebarPreviewHovered else { return }
            withAnimation(.easeOut(duration: 0.14)) {
                self.isSidebarPreviewVisible = false
            }
        }
        sidebarPreviewDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
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
        guard openingFileURLs.insert(normalized).inserted else { return }

        let byteCount = (try? FileService.fileByteCount(at: normalized)) ?? 0
        let profile = DocumentPerformanceProfile.resolve(byteCount: byteCount)
        if profile == .extreme, !confirmOpeningExtremeFile(normalized, byteCount: byteCount) {
            openingFileURLs.remove(normalized)
            return
        }

        let placeholder = EditorDocument(
            url: normalized,
            language: EditorLanguage.infer(from: normalized),
            byteCount: byteCount,
            performanceProfile: profile
        )
        placeholder.ioState = .opening
        if documents.count == 1, let blank = documents.first, blank.isDisposableBlank {
            stopObserving(blank)
            documents.removeAll()
        }
        documents.append(placeholder)
        observe(placeholder)
        selectedDocumentID = placeholder.id

        fileReadQueue.async { [weak self] in
            let readSignpostID = OSSignpostID(log: filePerformanceLog)
            os_signpost(
                .begin,
                log: filePerformanceLog,
                name: "FileOpen",
                signpostID: readSignpostID
            )
            let result = Result { try FileService.prepareRead(normalized) }
            os_signpost(
                .end,
                log: filePerformanceLog,
                name: "FileOpen",
                signpostID: readSignpostID
            )
            DispatchQueue.main.async { [weak self] in
                self?.finishOpeningFile(normalized, result: result)
            }
        }
    }

    private func finishOpeningFile(
        _ url: URL,
        result: Result<PreparedFileRead, Error>
    ) {
        openingFileURLs.remove(url)
        if cancelledOpeningURLs.remove(url) != nil {
            removeOpeningPlaceholder(for: url)
            return
        }
        do {
            let prepared = try result.get()
            let decoded: DecodedFile
            switch prepared {
            case let .decoded(value):
                decoded = value
            case let .needsEncoding(data, byteCount):
                decoded = try fileService.decodeUsingSelectedEncoding(
                    data,
                    from: url,
                    byteCount: byteCount
                )
            }
            insertOpenedFile(decoded, at: url)
        } catch CocoaError.userCancelled {
            removeOpeningPlaceholder(for: url)
            return
        } catch {
            if let placeholder = documents.first(where: {
                $0.url?.standardizedFileURL == url && $0.ioState == .opening
            }) {
                placeholder.ioState = .failed(error.localizedDescription)
            }
            presentError(title: "无法打开文件", error: error)
        }
    }

    func cancelOpening(_ document: EditorDocument) {
        guard document.ioState == .opening, let url = document.url else { return }
        cancelledOpeningURLs.insert(url.standardizedFileURL)
        removeOpeningPlaceholder(for: url.standardizedFileURL)
    }

    private func insertOpenedFile(_ decoded: DecodedFile, at url: URL) {
        if let existing = documents.first(where: {
            $0.url?.standardizedFileURL == url
        }) {
            if existing.ioState == .opening {
                existing.text = decoded.text
                existing.encodingName = decoded.encodingName
                existing.ioState = .idle
                existing.updatePerformanceProfile(
                    byteCount: decoded.byteCount,
                    lineCount: decoded.lineCount
                )
                existing.markSaved()
                selectedDocumentID = existing.id
                recentFiles.record(url)
            } else {
                selectedDocumentID = existing.id
            }
            return
        }
        let document = EditorDocument(
            text: decoded.text,
            url: url,
            language: EditorLanguage.infer(from: url),
            encodingName: decoded.encodingName,
            byteCount: decoded.byteCount,
            lineCount: decoded.lineCount
        )
        if documents.count == 1,
           let first = documents.first,
           first.isDisposableBlank {
            stopObserving(first)
            documents.removeAll()
        }
        documents.append(document)
        selectedDocumentID = document.id
        recentFiles.record(url)
        observe(document)
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

    func moveDocument(_ sourceID: UUID, before targetID: UUID?) {
        guard let sourceIndex = documents.firstIndex(where: {
            $0.id == sourceID
        }) else { return }
        if targetID == sourceID {
            selectedDocumentID = sourceID
            return
        }

        let document = documents.remove(at: sourceIndex)
        let destination = targetID.flatMap { targetID in
            documents.firstIndex(where: { $0.id == targetID })
        } ?? documents.endIndex
        documents.insert(document, at: destination)
        selectedDocumentID = sourceID
    }

    func takeDocumentForTransfer(_ document: EditorDocument) -> EditorDocument? {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else {
            return nil
        }
        document.refreshDirtyState()
        stopObserving(document)
        documents.remove(at: index)
        if documents.isEmpty {
            newDocument()
        } else {
            selectedDocumentID = documents[min(index, documents.count - 1)].id
        }
        return document
    }

    func receiveTransferredDocument(
        _ document: EditorDocument,
        before targetID: UUID? = nil
    ) {
        if documents.contains(where: {
            $0.id == document.id
        }) {
            moveDocument(document.id, before: targetID)
            selectedDocumentID = document.id
            return
        }

        if documents.count == 1, let blank = documents.first,
           blank.isDisposableBlank {
            stopObserving(blank)
            documents.removeAll()
        }

        let destination = targetID.flatMap { targetID in
            documents.firstIndex(where: { $0.id == targetID })
        } ?? documents.endIndex
        documents.insert(document, at: destination)
        observe(document)
        selectedDocumentID = document.id
    }

    func togglePreview() {
        guard let document = selectedDocument, document.language == .markdown else { return }
        document.synchronizeLiveText()
        if document.isLargeFileMode {
            document.featureOverrides.preview = !document.isPreviewEffectivelyEnabled
        } else {
            document.isPreviewVisible.toggle()
        }
    }

    func toggleWordWrap() {
        guard let document = selectedDocument else { return }
        if document.isLargeFileMode {
            document.setOverride(
                !document.effectiveWordWrap(globalDefault: isWordWrapEnabled),
                for: .wordWrap
            )
        } else {
            isWordWrapEnabled.toggle()
        }
    }

    func toggleLargeFileFeature(_ feature: DocumentManagedFeature) {
        guard let document = selectedDocument, document.isLargeFileMode else { return }
        let enabled: Bool
        switch feature {
        case .wordWrap:
            enabled = !document.effectiveWordWrap(globalDefault: isWordWrapEnabled)
        case .preview:
            enabled = !document.isPreviewEffectivelyEnabled
        case .syntaxHighlighting:
            enabled = !document.isSyntaxHighlightingEnabled
        case .folding:
            enabled = !document.isFoldingEnabled
        case .wordCount:
            enabled = !document.isWordCountEnabled
        }
        document.setOverride(enabled, for: feature)
    }

    func setLanguage(_ language: EditorLanguage) {
        guard let document = selectedDocument else { return }
        document.synchronizeLiveText()
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
        let source = document.synchronizedText()
        let revision = document.textRevision
        document.statusMessage = pretty ? "正在格式化 JSON…" : "正在压缩 JSON…"
        performDocumentTask(document, kind: .json) {
            Result { try JSONFormatter.format(source, pretty: pretty) }
        } completion: { [weak self, weak document] result in
            guard let self, let document,
                  self.isTaskResultCurrent(document, revision: revision) else { return }
            switch result {
            case let .success(formatted):
                self.applyTextUpdate(
                    formatted,
                    to: document,
                    selectionRange: document.selectionRange,
                    actionName: pretty ? "格式化 JSON" : "压缩 JSON"
                )
                document.statusMessage = pretty ? "JSON 已格式化" : "JSON 已压缩"
            case let .failure(error):
                document.statusMessage = JSONFormatter.userFacingError(error, in: source)
            }
        }
    }

    func presentFindReplace(mode: FindReplaceMode) {
        findReplace.mode = mode
        findReplace.message = nil
        guard let hostWindow else { return }
        let controller = findReplaceWindowController ?? FindReplaceWindowController(
            appState: self
        )
        findReplaceWindowController = controller
        controller.present(mode: mode, relativeTo: hostWindow)
    }

    func dismissFindReplace() {
        findReplaceWindowController?.dismiss()
        findReplaceWindowController = nil
    }

    func findNext() {
        guard let document = selectedDocument else { return }
        let source = document.synchronizedText()
        let query = interpretedSearchQuery()
        guard !query.isEmpty else {
            presentFindReplace(mode: .find)
            return
        }
        performFind(
            in: document,
            source: source,
            query: query,
            selection: document.selectionRange,
            backwards: false
        )
    }

    func findPrevious() {
        guard let document = selectedDocument else { return }
        let source = document.synchronizedText()
        let query = interpretedSearchQuery()
        guard !query.isEmpty else {
            presentFindReplace(mode: .find)
            return
        }
        performFind(
            in: document,
            source: source,
            query: query,
            selection: document.selectionRange,
            backwards: true
        )
    }

    func replaceCurrentMatch() {
        guard let document = selectedDocument else { return }
        let source = document.synchronizedText()
        let query = interpretedSearchQuery()
        guard !query.isEmpty else {
            findReplace.message = "请输入查找内容"
            return
        }
        guard TextSearchService.selectionMatches(
            in: source,
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
        let mutable = NSMutableString(string: source)
        let originalRange = document.selectionRange
        mutable.replaceCharacters(in: originalRange, with: replacement)
        let nextSelection = NSRange(
            location: originalRange.location,
            length: (replacement as NSString).length
        )
        applyTextUpdate(
            mutable as String,
            to: document,
            selectionRange: nextSelection,
            actionName: "替换"
        )
        findReplace.message = "已替换 1 处"
    }

    func replaceAllMatches() {
        guard let document = selectedDocument else { return }
        let source = document.synchronizedText()
        let query = interpretedSearchQuery()
        guard !query.isEmpty else {
            findReplace.message = "请输入查找内容"
            return
        }
        let replacement = TextSearchService.interpreted(
            findReplace.replacement,
            enabled: findReplace.interpretsEscapes
        )
        let revision = document.textRevision
        let rawQuery = findReplace.query
        let caseSensitive = findReplace.isCaseSensitive
        findReplace.isWorking = true
        findReplace.message = "正在替换…"
        performDocumentTask(document, kind: .replace) {
            TextSearchService.replacingAll(
                in: source,
                query: query,
                replacement: replacement,
                caseSensitive: caseSensitive
            )
        } completion: { [weak self, weak document] result in
            guard let self, let document else { return }
            self.findReplace.isWorking = false
            guard self.findReplace.query == rawQuery,
                  self.findReplace.isCaseSensitive == caseSensitive,
                  self.isTaskResultCurrent(document, revision: revision) else {
                self.findReplace.message = "内容已变化，已取消替换"
                return
            }
            guard result.count > 0 else {
                self.findReplace.message = "未找到匹配内容"
                return
            }
            self.applyTextUpdate(
                result.text,
                to: document,
                selectionRange: NSRange(location: 0, length: 0),
                actionName: "全部替换"
            )
            self.findReplace.message = "已替换 \(result.count) 处"
        }
    }

    func cancelFindReplaceTask() {
        guard findReplace.isWorking, let document = selectedDocument else { return }
        document.taskCoordinator.cancel(.search)
        document.taskCoordinator.cancel(.replace)
        findReplace.isWorking = false
        findReplace.message = "已取消"
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

    var isUsingDefaultFontSize: Bool {
        editorFontSize == defaultFontSize
    }

    func updateRenamedFileReference(from oldURL: URL, to newURL: URL) {
        for document in documents {
            document.updateLocationAfterRename(from: oldURL, to: newURL)
        }
    }

    func confirmClosingAllDocuments() -> Bool {
        documents.allSatisfy(confirmClosing)
    }

    private func observe(_ document: EditorDocument) {
        documentCancellables[document.id] = Publishers.MergeMany([
            document.$url.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            document.$language.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            document.$isDirty.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            document.$isPreviewVisible.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            document.$performanceProfile.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            document.$featureOverrides.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            document.$ioState.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ])
        .sink { [weak self] in self?.objectWillChange.send() }
    }

    private func stopObserving(_ document: EditorDocument) {
        document.taskCoordinator.cancel(.search)
        document.taskCoordinator.cancel(.replace)
        document.taskCoordinator.cancel(.json)
        document.taskCoordinator.cancel(.preview)
        document.taskCoordinator.cancel(.metrics)
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

    private func performFind(
        in document: EditorDocument,
        source: String,
        query: String,
        selection: NSRange,
        backwards: Bool
    ) {
        let revision = document.textRevision
        let rawQuery = findReplace.query
        let caseSensitive = findReplace.isCaseSensitive
        findReplace.isWorking = true
        findReplace.message = "正在查找…"
        performDocumentTask(document, kind: .search) {
            if backwards {
                TextSearchService.previousRange(
                    in: source,
                    query: query,
                    before: selection,
                    caseSensitive: caseSensitive
                )
            } else {
                TextSearchService.nextRange(
                    in: source,
                    query: query,
                    after: selection,
                    caseSensitive: caseSensitive
                )
            }
        } completion: { [weak self, weak document] range in
            guard let self, let document else { return }
            self.findReplace.isWorking = false
            guard self.findReplace.query == rawQuery,
                  self.findReplace.isCaseSensitive == caseSensitive,
                  self.isTaskResultCurrent(document, revision: revision) else {
                self.findReplace.message = "内容已变化，已取消查找"
                return
            }
            guard let range else {
                self.findReplace.message = "未找到匹配内容"
                return
            }
            self.reveal(range, in: document)
            self.findReplace.message = "已找到匹配内容"
        }
    }

    private func performDocumentTask<Result>(
        _ document: EditorDocument,
        kind: DocumentTaskCoordinator.Kind,
        work: @escaping () -> Result,
        completion: @escaping (Result) -> Void
    ) {
        let generation = document.taskCoordinator.begin(kind)
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak document, weak operation] in
            guard let document, let operation, !operation.isCancelled else { return }
            let signpostID = OSSignpostID(log: taskPerformanceLog)
            os_signpost(
                .begin,
                log: taskPerformanceLog,
                name: documentTaskSignpostName(for: kind),
                signpostID: signpostID
            )
            let result = work()
            os_signpost(
                .end,
                log: taskPerformanceLog,
                name: documentTaskSignpostName(for: kind),
                signpostID: signpostID
            )
            guard !operation.isCancelled,
                  document.taskCoordinator.isCurrent(generation, for: kind) else { return }
            DispatchQueue.main.async { [weak document] in
                guard let document,
                      document.taskCoordinator.isCurrent(generation, for: kind) else { return }
                document.taskCoordinator.finish(kind, generation: generation)
                completion(result)
            }
        }
        document.taskCoordinator.attach(operation, kind: kind, generation: generation)
        documentTaskQueue.addOperation(operation)
    }

    private func isTaskResultCurrent(
        _ document: EditorDocument,
        revision: UInt
    ) -> Bool {
        documents.contains(where: { $0.id == document.id })
            && document.textRevision == revision
            && !document.hasPendingLiveEdits
    }

    private func reveal(_ range: NSRange, in document: EditorDocument) {
        document.selectionRange = range
        NotificationCenter.default.post(
            name: EditorCommandNotification.revealSelection,
            object: EditorSelectionRequest(documentID: document.id, range: range)
        )
    }

    private func applyTextUpdate(
        _ text: String,
        to document: EditorDocument,
        selectionRange: NSRange,
        actionName: String
    ) {
        guard text != document.synchronizedText() else { return }
        let textLength = (text as NSString).length
        let safeLocation = min(selectionRange.location, textLength)
        let safeSelection = NSRange(
            location: safeLocation,
            length: min(selectionRange.length, textLength - safeLocation)
        )
        let request = EditorTextUpdateRequest(
            documentID: document.id,
            text: text,
            selectionRange: safeSelection,
            actionName: actionName
        )
        NotificationCenter.default.post(
            name: EditorCommandNotification.applyTextUpdate,
            object: request
        )

        guard !request.wasHandled else { return }
        document.text = text
        document.selectionRange = safeSelection
        document.refreshDirtyState()
    }

    private func write(_ document: EditorDocument, to url: URL) -> Bool {
        let text = document.synchronizedText()
        let revision = document.textRevision
        let saveGeneration = document.taskCoordinator.begin(.save)
        document.ioState = .saving
        document.statusMessage = "正在保存…"
        let signpostID = OSSignpostID(log: filePerformanceLog)
        fileWriteQueue.async { [weak self, weak document] in
            os_signpost(
                .begin,
                log: filePerformanceLog,
                name: "FileSave",
                signpostID: signpostID
            )
            let result = Result { try FileService.writeUTF8(text, to: url) }
            os_signpost(
                .end,
                log: filePerformanceLog,
                name: "FileSave",
                signpostID: signpostID
            )
            DispatchQueue.main.async {
                guard let self, let document else { return }
                guard document.taskCoordinator.isCurrent(
                    saveGeneration,
                    for: .save
                ) else { return }
                document.taskCoordinator.finish(.save, generation: saveGeneration)
                switch result {
                case .success:
                    document.updateLocation(to: url)
                    document.encodingName = "UTF-8"
                    document.markSaved(snapshot: text, revision: revision)
                    document.ioState = .idle
                    document.statusMessage = document.isDirty
                        ? "已保存先前版本，仍有未保存更改"
                        : nil
                    self.recentFiles.record(url)
                case let .failure(error):
                    document.ioState = .failed(error.localizedDescription)
                    document.statusMessage = "保存失败：\(error.localizedDescription)"
                    self.presentError(title: "无法保存文件", error: error)
                }
            }
        }
        return true
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
            return saveSynchronouslyForClosing(document)
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func saveSynchronouslyForClosing(_ document: EditorDocument) -> Bool {
        let targetURL: URL
        if let url = document.url {
            targetURL = url
        } else {
            guard let url = fileService.chooseSaveURL(
                suggestedName: suggestedFilename(for: document)
            ) else { return false }
            targetURL = url
        }
        do {
            let snapshot = document.synchronizedText()
            document.taskCoordinator.cancel(.save)
            var writeResult: Result<Void, Error>!
            fileWriteQueue.sync {
                writeResult = Result {
                    try FileService.writeUTF8(snapshot, to: targetURL)
                }
            }
            try writeResult.get()
            document.updateLocation(to: targetURL)
            document.encodingName = "UTF-8"
            document.markSaved()
            document.ioState = .idle
            recentFiles.record(targetURL)
            return true
        } catch {
            presentError(title: "无法保存文件", error: error)
            return false
        }
    }

    private func removeOpeningPlaceholder(for url: URL) {
        guard let placeholder = documents.first(where: {
            $0.url?.standardizedFileURL == url && $0.ioState == .opening
        }) else { return }
        removeDocument(placeholder)
    }

    private func confirmOpeningExtremeFile(_ url: URL, byteCount: Int) -> Bool {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "打开超大文件？"
        alert.informativeText = "“\(url.lastPathComponent)”大小为 \(formatter.string(fromByteCount: Int64(byteCount)))。LacEditor 将进入保护模式并关闭高亮、预览、换行、折叠和实时字数统计。"
        alert.addButton(withTitle: "继续打开")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
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
