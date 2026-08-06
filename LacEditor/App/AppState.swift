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
    case .textTransformation: "TextTransformation"
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
    static let extractTextSelection = Notification.Name(
        "LacEditor.extractTextSelection"
    )
    static let applyRangeReplacement = Notification.Name(
        "LacEditor.applyRangeReplacement"
    )
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

struct EditorTextSelectionSnapshot {
    let documentID: UUID
    let range: NSRange
    let text: String
    let editorRevision: UInt
    let wasExplicitSelection: Bool
}

final class EditorTextExtractionRequest {
    let documentID: UUID
    let allowsTokenAtCaret: Bool
    var result: EditorTextSelectionSnapshot?

    init(documentID: UUID, allowsTokenAtCaret: Bool) {
        self.documentID = documentID
        self.allowsTokenAtCaret = allowsTokenAtCaret
    }
}

final class EditorRangeReplacementRequest {
    let documentID: UUID
    let range: NSRange
    let originalText: String
    let replacementText: String
    let expectedEditorRevision: UInt
    let actionName: String
    var wasHandled = false
    var failureMessage: String?

    init(
        documentID: UUID,
        range: NSRange,
        originalText: String,
        replacementText: String,
        expectedEditorRevision: UInt,
        actionName: String
    ) {
        self.documentID = documentID
        self.range = range
        self.originalText = originalText
        self.replacementText = replacementText
        self.expectedEditorRevision = expectedEditorRevision
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
    @Published var selectedDocumentID: UUID? {
        didSet {
            guard oldValue != selectedDocumentID,
                  findReplace.isWorking,
                  let activeID = findReplace.activeDocumentID,
                  activeID != selectedDocumentID else { return }
            documents.first(where: { $0.id == activeID })?.taskCoordinator.cancel(.search)
            documents.first(where: { $0.id == activeID })?.taskCoordinator.cancel(.replace)
            findReplace.isWorking = false
            findReplace.activeDocumentID = nil
            findReplace.message = "目标标签已切换，查找已取消"
        }
    }
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
    var isWordWrapEnabled: Bool {
        get { preferences.wordWrapEnabled }
        set { preferences.wordWrapEnabled = newValue }
    }
    var editorFontSize: CGFloat {
        get { preferences.editorFontSize }
        set { preferences.editorFontSize = newValue }
    }
    var isLineNumbersVisible: Bool {
        get { preferences.lineNumbersVisible }
        set { preferences.lineNumbersVisible = newValue }
    }
    var isStatusBarVisible: Bool {
        get { preferences.statusBarVisible }
        set { preferences.statusBarVisible = newValue }
    }
    var theme: AppTheme {
        get { preferences.theme }
        set { preferences.theme = newValue }
    }

    let recentFiles: RecentFilesStore
    let preferences: AppPreferences
    let findReplace = FindReplaceState()
    let textTransformation = TextTransformationPreviewState()
    weak var hostWindow: NSWindow?
    weak var windowManager: WindowManager?
    private var findReplaceWindowController: FindReplaceWindowController?
    private var textTransformationWindowController: TextTransformationWindowController?
    private let fileService = FileService()
    private let fileReadQueue = DispatchQueue(
        label: "com.laceditor.file-reading",
        qos: .userInitiated
    )
    private let fileOpeningQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.laceditor.file-opening"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
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
    private var openingOperations: [URL: Operation] = [:]
    private var cancelledOpeningURLs: Set<URL> = []
    private var sidebarPreviewDismissWorkItem: DispatchWorkItem?
    private var contentChangeObserver: NSObjectProtocol?
    private var preferencesCancellable: AnyCancellable?

    init(
        initialDocument: EditorDocument? = nil,
        recentFiles: RecentFilesStore,
        preferences: AppPreferences
    ) {
        self.recentFiles = recentFiles
        self.preferences = preferences
        isSidebarVisible = UserDefaults.standard.object(
            forKey: "isSidebarVisible"
        ) as? Bool ?? true
        preferencesCancellable = preferences.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
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
                document.taskCoordinator.cancel(.textTransformation)
                if document.statusMessage?.hasPrefix("正在格式化") == true
                    || document.statusMessage?.hasPrefix("正在压缩") == true {
                    document.statusMessage = "内容已变化，JSON 操作已取消"
                }
                if self.findReplace.isWorking {
                    self.findReplace.isWorking = false
                    self.findReplace.message = "内容已变化，任务已取消"
                }
                self.textTransformation.invalidate(documentID: documentID)
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
        if let windowManager {
            windowManager.openFile(url, preferredState: self)
            return
        }
        beginOpeningFile(url)
    }

    func beginOpeningFile(_ url: URL) {
        let normalized = url.standardizedFileURL
        var retryPlaceholder: EditorDocument?
        if let existing = documents.first(where: {
            $0.fileIdentity?.matches(DocumentFileIdentity.resolve(normalized)) == true
        }) {
            selectedDocumentID = existing.id
            if case .failed = existing.ioState {
                retryPlaceholder = existing
                openingFileURLs.remove(normalized)
            } else {
                return
            }
        }
        guard openingFileURLs.insert(normalized).inserted else { return }

        let byteCount = (try? FileService.fileByteCount(at: normalized)) ?? 0
        let profile = DocumentPerformanceProfile.resolve(byteCount: byteCount)
        if profile == .extreme, !confirmOpeningExtremeFile(normalized, byteCount: byteCount) {
            openingFileURLs.remove(normalized)
            return
        }

        let placeholder: EditorDocument
        if let retryPlaceholder {
            placeholder = retryPlaceholder
            placeholder.ioState = .opening
            placeholder.updatePerformanceProfile(byteCount: byteCount, lineCount: 0)
        } else {
            placeholder = EditorDocument(
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
        }
        selectedDocumentID = placeholder.id

        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
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
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async { [weak self, weak operation] in
                guard operation?.isCancelled == false else { return }
                self?.finishOpeningFile(normalized, result: result)
            }
        }
        openingOperations[normalized] = operation
        fileOpeningQueue.addOperation(operation)
    }

    private func finishOpeningFile(
        _ url: URL,
        result: Result<PreparedFileRead, Error>
    ) {
        openingFileURLs.remove(url)
        openingOperations.removeValue(forKey: url)
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
                guard let choice = fileService.chooseEncoding(for: url) else {
                    removeOpeningPlaceholder(for: url)
                    return
                }
                decodeOpeningFileInBackground(
                    data,
                    choice: choice,
                    byteCount: byteCount,
                    url: url
                )
                return
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

    private func decodeOpeningFileInBackground(
        _ data: Data,
        choice: FileEncodingChoice,
        byteCount: Int,
        url: URL
    ) {
        openingFileURLs.insert(url)
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let result = Result {
                try FileService.decode(
                    data,
                    encoding: choice.encoding,
                    encodingName: choice.name,
                    byteCount: byteCount
                )
            }
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async { [weak self, weak operation] in
                guard let self else { return }
                guard operation?.isCancelled == false else { return }
                self.openingFileURLs.remove(url)
                self.openingOperations.removeValue(forKey: url)
                if self.cancelledOpeningURLs.remove(url) != nil {
                    self.removeOpeningPlaceholder(for: url)
                    return
                }
                do {
                    self.insertOpenedFile(try result.get(), at: url)
                } catch {
                    if let placeholder = self.documents.first(where: {
                        $0.url?.standardizedFileURL == url && $0.ioState == .opening
                    }) {
                        placeholder.ioState = .failed(error.localizedDescription)
                    }
                    self.presentError(title: "无法打开文件", error: error)
                }
            }
        }
        openingOperations[url] = operation
        fileOpeningQueue.addOperation(operation)
    }

    func cancelOpening(_ document: EditorDocument) {
        guard document.ioState == .opening, let url = document.url else { return }
        openingOperations.removeValue(forKey: url.standardizedFileURL)?.cancel()
        cancelledOpeningURLs.insert(url.standardizedFileURL)
        removeOpeningPlaceholder(for: url.standardizedFileURL)
    }

    private func insertOpenedFile(_ decoded: DecodedFile, at url: URL) {
        if let existing = documents.first(where: {
            $0.url?.standardizedFileURL == url
        }) {
            if existing.ioState == .opening {
                existing.text = decoded.text
                existing.updateFileEncoding(decoded.encoding)
                existing.updateFileRevisionSnapshot(
                    try? FileRevisionSnapshot.capture(url)
                )
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
            fileEncoding: decoded.encoding,
            fileRevisionSnapshot: try? FileRevisionSnapshot.capture(url),
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
        guard let document = document ?? selectedDocument else { return false }
        return saveAs(document, encoding: document.fileEncoding, completion: nil)
    }

    private func saveAs(
        _ document: EditorDocument,
        encoding: String.Encoding,
        completion: ((Bool) -> Void)?
    ) -> Bool {
        guard let url = fileService.chooseSaveURL(
            suggestedName: suggestedFilename(for: document)
        ) else {
            completion?(false)
            return false
        }
        if let conflict = windowManager?.conflictingDocument(
            at: url,
            excluding: document.id
        ) {
            windowManager?.focus(conflict.document, in: conflict.state)
            let error = NSError(
                domain: "LacEditor",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "该文件已在 LacEditor 的另一个标签中打开。"]
            )
            presentError(title: "无法另存为", error: error)
            completion?(false)
            return false
        }
        document.updateFileEncoding(encoding)
        return write(document, to: url, completion: completion)
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
        confirmClosing(document) { [weak self, weak document] shouldClose in
            guard shouldClose, let self, let document else { return }
            self.removeDocument(document)
        }
    }

    func closeOtherDocuments(keeping document: EditorDocument) {
        let others = documents.filter { $0.id != document.id }
        closeDocumentsSequentially(others) { [weak self, weak document] completed in
            guard completed, let self, let document else { return }
            self.documents = [document]
            self.selectedDocumentID = document.id
        }
    }

    func closeDocumentsToRight(of document: EditorDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }),
              index + 1 < documents.count else { return }
        let right = Array(documents[(index + 1)...])
        closeDocumentsSequentially(right) { [weak self, weak document] completed in
            guard completed, let self, let document else { return }
            self.selectedDocumentID = document.id
        }
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

    func presentTextTransformation(_ operation: TextTransformationOperation) {
        guard let document = selectedDocument else { return }
        let extraction = EditorTextExtractionRequest(
            documentID: document.id,
            allowsTokenAtCaret: operation == .smartDecode
        )
        NotificationCenter.default.post(
            name: EditorCommandNotification.extractTextSelection,
            object: extraction
        )
        guard let snapshot = extraction.result else {
            document.statusMessage = operation == .smartDecode
                ? "请将光标放在编码内容中，或先选择文本"
                : "请先选择需要转换的文本"
            return
        }

        let inputByteCount = snapshot.text.utf8.count
        guard inputByteCount <= TextCodecService.maximumInputByteLimit else {
            document.statusMessage = "选区超过 32 MB，请拆分后再转换"
            return
        }
        if inputByteCount > TextCodecService.warningInputByteLimit,
           !confirmLargeTextTransformation(
                byteCount: inputByteCount,
                operation: operation
           ) {
            document.statusMessage = nil
            return
        }

        document.statusMessage = "正在转换文本…"
        performCancellableDocumentTask(document, kind: .textTransformation) { isCancelled in
            Result { () -> TextTransformationPreview in
                let detected = operation == .smartDecode
                    ? TextCodecService.detect(
                        in: snapshot.text,
                        allowsBase64: snapshot.wasExplicitSelection
                    )
                    : nil
                if operation == .smartDecode, detected == nil {
                    throw TextCodecError.noDetectedEncoding
                }
                let resolvedOperation = detected?.operation ?? operation
                let output: String
                if let detected {
                    output = detected.output
                } else {
                    output = try TextCodecService.transform(
                        snapshot.text,
                        operation: resolvedOperation,
                        isCancelled: isCancelled
                    )
                }
                return TextTransformationPreview(
                    documentID: document.id,
                    range: snapshot.range,
                    input: snapshot.text,
                    output: output,
                    editorRevision: snapshot.editorRevision,
                    operation: resolvedOperation,
                    detectedKind: detected?.kind
                )
            }
        } completion: { [weak self, weak document] result in
            guard let self, let document,
                  self.documents.contains(where: { $0.id == document.id }) else { return }
            switch result {
            case let .success(preview):
                document.statusMessage = nil
                self.textTransformation.present(preview)
                let controller = self.textTransformationWindowController
                    ?? TextTransformationWindowController(appState: self)
                self.textTransformationWindowController = controller
                if let hostWindow = self.hostWindow {
                    controller.present(relativeTo: hostWindow)
                }
            case let .failure(error):
                document.statusMessage = error.localizedDescription
            }
        }
    }

    func applyTextTransformationPreview() {
        guard textTransformation.canReplace,
              let preview = textTransformation.preview else {
            textTransformation.message = "编辑内容已变化，请重新执行转换"
            return
        }
        guard let document = documents.first(where: { $0.id == preview.documentID }) else {
            textTransformation.message = "原文标签已关闭，请重新执行转换"
            return
        }
        let request = EditorRangeReplacementRequest(
            documentID: preview.documentID,
            range: preview.range,
            originalText: preview.input,
            replacementText: preview.output,
            expectedEditorRevision: preview.editorRevision,
            actionName: preview.operation.actionName
        )
        NotificationCenter.default.post(
            name: EditorCommandNotification.applyRangeReplacement,
            object: request
        )
        guard request.wasHandled else {
            textTransformation.message = request.failureMessage
                ?? "编辑内容已变化，请重新执行转换"
            return
        }
        document.statusMessage = "已完成 \(preview.operation.title)"
        dismissTextTransformation()
    }

    func copyTextTransformationResult() {
        guard let output = textTransformation.preview?.output else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        textTransformation.message = "结果已复制"
    }

    func dismissTextTransformation() {
        textTransformationWindowController?.dismiss()
    }

    func closeAuxiliaryWindows() {
        dismissFindReplace()
        openingOperations.values.forEach { $0.cancel() }
        openingOperations.removeAll()
        documentTaskQueue.cancelAllOperations()
        documents.forEach { $0.taskCoordinator.cancelAll() }
        textTransformationWindowController?.dispose()
        textTransformationWindowController = nil
        textTransformation.clear()
    }

    private func confirmLargeTextTransformation(
        byteCount: Int,
        operation: TextTransformationOperation
    ) -> Bool {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let multiplier = operation == .urlEncodeComponent ? 3 : 2
        let estimated = Int64(byteCount * multiplier)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "转换较大的文本选区？"
        alert.informativeText = "选区大小为 \(formatter.string(fromByteCount: Int64(byteCount)))，预计最多产生约 \(formatter.string(fromByteCount: estimated)) 的结果。转换期间可继续使用其他标签。"
        alert.addButton(withTitle: "继续转换")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
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
        if let documentID = findReplace.activeDocumentID,
           let document = documents.first(where: { $0.id == documentID }) {
            document.taskCoordinator.cancel(.search)
            document.taskCoordinator.cancel(.replace)
        }
        findReplace.isWorking = false
        findReplace.activeDocumentID = nil
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
        findReplace.activeDocumentID = document.id
        findReplace.message = "正在替换…"
        performCancellableDocumentTask(document, kind: .replace) { isCancelled in
            TextSearchService.replacingAll(
                in: source,
                query: query,
                replacement: replacement,
                caseSensitive: caseSensitive,
                isCancelled: isCancelled
            )
        } completion: { [weak self, weak document] result in
            guard let self, let document else { return }
            guard self.findReplace.activeDocumentID == document.id else { return }
            self.findReplace.isWorking = false
            self.findReplace.activeDocumentID = nil
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
        guard findReplace.isWorking,
              let documentID = findReplace.activeDocumentID,
              let document = documents.first(where: { $0.id == documentID }) else { return }
        document.taskCoordinator.cancel(.search)
        document.taskCoordinator.cancel(.replace)
        findReplace.isWorking = false
        findReplace.activeDocumentID = nil
        findReplace.message = "已取消"
    }

    func increaseFontSize() {
        editorFontSize = min(editorFontSize + 1, 32)
    }

    func decreaseFontSize() {
        editorFontSize = max(editorFontSize - 1, 9)
    }

    func resetFontSize() {
        editorFontSize = AppPreferences.defaultFontSize
    }

    var isUsingDefaultFontSize: Bool {
        editorFontSize == AppPreferences.defaultFontSize
    }

    func updateRenamedFileReference(from oldURL: URL, to newURL: URL) {
        for document in documents {
            document.updateLocationAfterRename(from: oldURL, to: newURL)
        }
    }

    func confirmClosingAllDocuments(completion: @escaping (Bool) -> Void) {
        closeDocumentsSequentially(documents, removesDocuments: false, completion: completion)
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
        document.taskCoordinator.cancel(.textTransformation)
        textTransformation.invalidate(documentID: document.id)
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
        findReplace.activeDocumentID = document.id
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
            guard self.findReplace.activeDocumentID == document.id else { return }
            self.findReplace.isWorking = false
            self.findReplace.activeDocumentID = nil
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

    private func performCancellableDocumentTask<Result>(
        _ document: EditorDocument,
        kind: DocumentTaskCoordinator.Kind,
        work: @escaping (@escaping () -> Bool) -> Result,
        completion: @escaping (Result) -> Void
    ) {
        let generation = document.taskCoordinator.begin(kind)
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak document, weak operation] in
            guard let document, let operation, !operation.isCancelled else { return }
            let signpostID = OSSignpostID(log: taskPerformanceLog)
            os_signpost(.begin, log: taskPerformanceLog, name: documentTaskSignpostName(for: kind), signpostID: signpostID)
            let result = work { operation.isCancelled }
            os_signpost(.end, log: taskPerformanceLog, name: documentTaskSignpostName(for: kind), signpostID: signpostID)
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

    private func write(
        _ document: EditorDocument,
        to url: URL,
        bypassExternalConflict: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) -> Bool {
        guard document.ioState != .saving else {
            document.statusMessage = "已有保存任务正在进行"
            completion?(false)
            return false
        }
        if !bypassExternalConflict,
           url.standardizedFileURL == document.url?.standardizedFileURL,
           hasExternalFileConflict(document, at: url) {
            resolveExternalFileConflict(for: document, at: url, completion: completion)
            return false
        }
        let text = document.synchronizedText()
        let revision = document.textRevision
        let encoding = document.fileEncoding
        let encodingName = document.encodingName
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
            let saveResult: DocumentSaveResult
            let saveError: Error?
            do {
                try FileService.write(
                    text,
                    to: url,
                    encoding: encoding,
                    encodingName: encodingName
                )
                saveResult = DocumentSaveResult(
                    targetURL: url,
                    encoding: encoding,
                    snapshotRevision: revision,
                    fileRevisionSnapshot: try FileRevisionSnapshot.capture(url),
                    errorDescription: nil
                )
                saveError = nil
            } catch {
                saveResult = DocumentSaveResult(
                    targetURL: url,
                    encoding: encoding,
                    snapshotRevision: revision,
                    fileRevisionSnapshot: nil,
                    errorDescription: error.localizedDescription
                )
                saveError = error
            }
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
                if saveResult.succeeded,
                   let fileSnapshot = saveResult.fileRevisionSnapshot {
                    document.updateLocation(to: url)
                    document.updateFileEncoding(encoding)
                    document.updateFileRevisionSnapshot(fileSnapshot)
                    document.markSaved(snapshot: text, revision: revision)
                    document.ioState = .idle
                    document.statusMessage = document.isDirty
                        ? "已保存先前版本，仍有未保存更改"
                        : nil
                    self.recentFiles.record(url)
                    completion?(!document.isDirty)
                } else {
                    let description = saveResult.errorDescription ?? "无法取得保存后的文件状态"
                    document.ioState = .failed(description)
                    document.statusMessage = "保存失败：\(description)"
                    if let saveError {
                        self.handleSaveError(
                            saveError,
                            for: document,
                            completion: completion
                        )
                    } else {
                        completion?(false)
                    }
                }
            }
        }
        return true
    }

    private func hasExternalFileConflict(
        _ document: EditorDocument,
        at url: URL
    ) -> Bool {
        guard let baseline = document.fileRevisionSnapshot else { return false }
        guard let current = try? FileRevisionSnapshot.capture(url) else { return true }
        return current != baseline
    }

    private func resolveExternalFileConflict(
        for document: EditorDocument,
        at url: URL,
        completion: ((Bool) -> Void)?
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "磁盘上的文件已发生变化"
        alert.informativeText = "为避免覆盖其他程序的修改，LacEditor 已停止保存。你可以重新载入磁盘版本、另存为新文件，或明确覆盖。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "重新载入")
        alert.addButton(withTitle: "另存为")
        alert.addButton(withTitle: "仍然覆盖")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self, weak document] response in
            guard let self, let document else { return }
            switch response {
            case .alertSecondButtonReturn:
                self.reloadFromDisk(document, at: url)
                completion?(false)
            case .alertThirdButtonReturn:
                _ = self.saveAs(
                    document,
                    encoding: document.fileEncoding,
                    completion: completion
                )
            case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
                _ = self.write(
                    document,
                    to: url,
                    bypassExternalConflict: true,
                    completion: completion
                )
            default:
                completion?(false)
                break
            }
        }
        if let hostWindow {
            alert.beginSheetModal(for: hostWindow, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    private func reloadFromDisk(_ document: EditorDocument, at url: URL) {
        let expectedRevision = document.textRevision
        document.ioState = .opening
        fileReadQueue.async { [weak self, weak document] in
            let result = Result { try FileService.prepareRead(url) }
            DispatchQueue.main.async {
                guard let self, let document else { return }
                do {
                    let prepared = try result.get()
                    switch prepared {
                    case let .decoded(decoded):
                        guard document.textRevision == expectedRevision else {
                            document.ioState = .idle
                            document.statusMessage = "重新载入期间内容已变化，已保留本地修改"
                            return
                        }
                        document.text = decoded.text
                        document.updateFileEncoding(decoded.encoding)
                        document.updateFileRevisionSnapshot(try? FileRevisionSnapshot.capture(url))
                        document.markSaved()
                        document.ioState = .idle
                    case let .needsEncoding(data, byteCount):
                        guard let choice = self.fileService.chooseEncoding(for: url) else {
                            document.ioState = .idle
                            return
                        }
                        self.decodeReloadInBackground(
                            data,
                            choice: choice,
                            byteCount: byteCount,
                            document: document,
                            url: url,
                            expectedRevision: expectedRevision
                        )
                    }
                } catch {
                    document.ioState = .failed(error.localizedDescription)
                    self.presentError(title: "无法重新载入文件", error: error)
                }
            }
        }
    }

    private func decodeReloadInBackground(
        _ data: Data,
        choice: FileEncodingChoice,
        byteCount: Int,
        document: EditorDocument,
        url: URL,
        expectedRevision: UInt
    ) {
        fileReadQueue.async { [weak self, weak document] in
            let result = Result {
                try FileService.decode(
                    data,
                    encoding: choice.encoding,
                    encodingName: choice.name,
                    byteCount: byteCount
                )
            }
            DispatchQueue.main.async {
                guard let self, let document else { return }
                do {
                    let decoded = try result.get()
                    guard document.textRevision == expectedRevision else {
                        document.ioState = .idle
                        document.statusMessage = "重新载入期间内容已变化，已保留本地修改"
                        return
                    }
                    document.text = decoded.text
                    document.updateFileEncoding(decoded.encoding)
                    document.updateFileRevisionSnapshot(try? FileRevisionSnapshot.capture(url))
                    document.markSaved()
                    document.ioState = .idle
                } catch {
                    document.ioState = .failed(error.localizedDescription)
                    self.presentError(title: "无法重新载入文件", error: error)
                }
            }
        }
    }

    private func handleSaveError(
        _ error: Error,
        for document: EditorDocument,
        completion: ((Bool) -> Void)?
    ) {
        guard case FileServiceError.unrepresentableCharacters = error else {
            presentError(title: "无法保存文件", error: error)
            completion?(false)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "当前编码无法保存这些字符"
        alert.informativeText = "原文件没有被覆盖。你可以取消，或另存为 UTF-8 文件。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "另存为 UTF-8")
        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else {
            completion?(false)
            return
        }
        _ = saveAs(document, encoding: .utf8, completion: completion)
    }

    private func confirmClosing(
        _ document: EditorDocument,
        completion: @escaping (Bool) -> Void
    ) {
        document.refreshDirtyState()
        guard document.isDirty else {
            completion(true)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "要保存对“\(document.displayName)”的更改吗？"
        alert.informativeText = "如果不保存，更改将会丢失。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self, weak document] response in
            guard let self, let document else {
                completion(false)
                return
            }
            switch response {
            case .alertFirstButtonReturn:
                self.saveForClosing(document, completion: completion)
            case .alertSecondButtonReturn:
                completion(true)
            default:
                completion(false)
            }
        }
        if let hostWindow {
            alert.beginSheetModal(for: hostWindow, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    private func saveForClosing(
        _ document: EditorDocument,
        completion: @escaping (Bool) -> Void
    ) {
        let targetURL: URL
        if let url = document.url {
            targetURL = url
        } else {
            guard let url = fileService.chooseSaveURL(
                suggestedName: suggestedFilename(for: document)
            ) else {
                completion(false)
                return
            }
            targetURL = url
        }
        if let conflict = windowManager?.conflictingDocument(
            at: targetURL,
            excluding: document.id
        ) {
            windowManager?.focus(conflict.document, in: conflict.state)
            completion(false)
            return
        }
        _ = write(document, to: targetURL, completion: completion)
    }

    private func closeDocumentsSequentially(
        _ queue: [EditorDocument],
        removesDocuments: Bool = true,
        completion: @escaping (Bool) -> Void
    ) {
        guard let document = queue.first else {
            completion(true)
            return
        }
        confirmClosing(document) { [weak self] shouldClose in
            guard let self, shouldClose else {
                completion(false)
                return
            }
            if removesDocuments,
               self.documents.contains(where: { $0.id == document.id }) {
                self.removeDocument(document)
            }
            self.closeDocumentsSequentially(
                Array(queue.dropFirst()),
                removesDocuments: removesDocuments,
                completion: completion
            )
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
