import Foundation

enum DocumentPerformanceProfile: String, CaseIterable, Identifiable {
    case standard
    case large
    case extreme

    static let largeFileByteThreshold = 20 * 1_024 * 1_024
    static let extremeFileByteThreshold = 50 * 1_024 * 1_024
    static let largeFileLineThreshold = 250_000

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: "标准模式"
        case .large: "大文件模式"
        case .extreme: "超大文件保护模式"
        }
    }

    static func resolve(byteCount: Int, lineCount: Int = 0) -> Self {
        if byteCount > extremeFileByteThreshold { return .extreme }
        if byteCount > largeFileByteThreshold || lineCount > largeFileLineThreshold {
            return .large
        }
        return .standard
    }
}

struct DocumentFeatureOverrides: Equatable {
    var wordWrap: Bool?
    var preview: Bool?
    var syntaxHighlighting: Bool?
    var folding: Bool?
    var wordCount: Bool?
}

enum DocumentManagedFeature {
    case wordWrap
    case preview
    case syntaxHighlighting
    case folding
    case wordCount
}

enum DocumentIOState: Equatable {
    case idle
    case opening
    case saving
    case failed(String)

    var statusText: String? {
        switch self {
        case .idle: nil
        case .opening: "正在打开"
        case .saving: "正在保存"
        case let .failed(message): message
        }
    }
}

final class DocumentTaskCoordinator: @unchecked Sendable {
    enum Kind: Hashable {
        case search
        case replace
        case json
        case preview
        case metrics
        case save
        case listNormalization
        case delimiterMatch
    }

    private let lock = NSLock()
    private var generations: [Kind: UInt] = [:]
    private var operations: [Kind: Operation] = [:]

    @discardableResult
    func begin(_ kind: Kind, operation: Operation? = nil) -> UInt {
        lock.lock()
        defer { lock.unlock() }
        operations[kind]?.cancel()
        let generation = (generations[kind] ?? 0) &+ 1
        generations[kind] = generation
        operations[kind] = operation
        return generation
    }

    func attach(_ operation: Operation, kind: Kind, generation: UInt) {
        lock.lock()
        defer { lock.unlock() }
        guard generations[kind] == generation else {
            operation.cancel()
            return
        }
        operations[kind] = operation
    }

    func isCurrent(_ generation: UInt, for kind: Kind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations[kind] == generation && operations[kind]?.isCancelled != true
    }

    func finish(_ kind: Kind, generation: UInt) {
        lock.lock()
        defer { lock.unlock() }
        if generations[kind] == generation { operations[kind] = nil }
    }

    func cancel(_ kind: Kind) {
        lock.lock()
        defer { lock.unlock() }
        operations[kind]?.cancel()
        operations[kind] = nil
        generations[kind] = (generations[kind] ?? 0) &+ 1
    }

    func cancelAll() {
        lock.lock()
        defer { lock.unlock() }
        operations.values.forEach { $0.cancel() }
        operations.removeAll()
        for kind in generations.keys {
            generations[kind] = (generations[kind] ?? 0) &+ 1
        }
    }
}

final class EditorDocument: ObservableObject, Identifiable, @unchecked Sendable {
    let id = UUID()
    @Published var text: String {
        didSet {
            hasPendingLiveEdits = false
            pendingLiveTextIsEmpty = nil
            textRevision &+= 1
            scheduleMetricsRefresh()
        }
    }
    @Published var url: URL?
    @Published var language: EditorLanguage
    @Published var encodingName: String
    @Published var isDirty: Bool
    @Published var cursorLine = 1
    @Published var cursorColumn = 1
    @Published var selectionRange = NSRange(location: 0, length: 0)
    @Published var statusMessage: String?
    @Published var isPreviewVisible: Bool
    @Published var performanceProfile: DocumentPerformanceProfile
    @Published var featureOverrides = DocumentFeatureOverrides()
    @Published var ioState: DocumentIOState = .idle
    @Published private(set) var wordCount: Int
    private(set) var textRevision: UInt = 0
    var scrollPositionRatio: CGFloat = 0
    var foldedRange: NSRange?
    let taskCoordinator = DocumentTaskCoordinator()
    private var savedText: String
    private var liveTextProviderID: UUID?
    private var liveTextProvider: (() -> String?)?
    private var liveTextAcknowledgement: ((UInt) -> Void)?
    private(set) var hasPendingLiveEdits = false
    private var pendingLiveTextIsEmpty: Bool?
    private var isUpdatingDirtyState = false
    private var metricsGeneration: UInt = 0
    private let metricsQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private var metricsOperation: BlockOperation?
    private var metricsDebounceWorkItem: DispatchWorkItem?

    init(
        text: String = "",
        url: URL? = nil,
        language: EditorLanguage = .plainText,
        encodingName: String = "UTF-8",
        isDirty: Bool = false,
        byteCount: Int? = nil,
        lineCount: Int? = nil,
        performanceProfile: DocumentPerformanceProfile? = nil
    ) {
        self.text = text
        self.url = url
        self.language = language
        self.encodingName = encodingName
        self.isDirty = isDirty
        let resolvedProfile = performanceProfile ?? .resolve(
            byteCount: byteCount ?? text.utf8.count,
            lineCount: lineCount ?? Self.countLines(in: text)
        )
        self.performanceProfile = resolvedProfile
        self.isPreviewVisible = language == .markdown && resolvedProfile == .standard
        self.savedText = text
        self.wordCount = text.utf16.count < 100_000
            ? Self.countWords(in: text)
            : 0
        if text.utf16.count >= 100_000 {
            scheduleMetricsRefresh()
        }
    }

    deinit {
        taskCoordinator.cancelAll()
        metricsDebounceWorkItem?.cancel()
        metricsOperation?.cancel()
        metricsQueue.cancelAllOperations()
    }

    var displayName: String {
        url?.lastPathComponent ?? "未命名"
    }

    var isDisposableBlank: Bool {
        let isEmpty = hasPendingLiveEdits
            ? pendingLiveTextIsEmpty ?? text.isEmpty
            : text.isEmpty
        return url == nil && isEmpty && !isDirty
    }

    var lineCount: Int {
        Self.countLines(in: text)
    }

    var isLargeFileMode: Bool { performanceProfile != .standard }

    func effectiveWordWrap(globalDefault: Bool) -> Bool {
        featureOverrides.wordWrap ?? (performanceProfile == .standard ? globalDefault : false)
    }

    var isPreviewEffectivelyEnabled: Bool {
        language == .markdown && (featureOverrides.preview ?? (
            performanceProfile == .standard && isPreviewVisible
        ))
    }

    var isSyntaxHighlightingEnabled: Bool {
        featureOverrides.syntaxHighlighting ?? (performanceProfile != .extreme)
    }

    var isFoldingEnabled: Bool {
        featureOverrides.folding ?? (performanceProfile == .standard)
    }

    var isWordCountEnabled: Bool {
        featureOverrides.wordCount ?? (performanceProfile == .standard)
    }

    func updatePerformanceProfile(byteCount: Int? = nil, lineCount: Int? = nil) {
        let next = DocumentPerformanceProfile.resolve(
            byteCount: byteCount ?? text.utf8.count,
            lineCount: lineCount ?? self.lineCount
        )
        guard next != performanceProfile else { return }
        performanceProfile = next
        if next != .standard { isPreviewVisible = false }
        scheduleMetricsRefresh()
    }

    func setOverride(_ enabled: Bool, for feature: DocumentManagedFeature) {
        switch feature {
        case .wordWrap: featureOverrides.wordWrap = enabled
        case .preview: featureOverrides.preview = enabled
        case .syntaxHighlighting: featureOverrides.syntaxHighlighting = enabled
        case .folding: featureOverrides.folding = enabled
        case .wordCount:
            featureOverrides.wordCount = enabled
            scheduleMetricsRefresh()
        }
    }

    private static func countLines(in text: String) -> Int {
        let value = text as NSString
        var count = 1
        var location = 0
        while location < value.length {
            let character = value.character(at: location)
            if character == 0x0D,
               location + 1 < value.length,
               value.character(at: location + 1) == 0x0A {
                count += 1
                location += 2
                continue
            }
            if character == 0x0A
                || character == 0x0D
                || character == 0x2028
                || character == 0x2029 {
                count += 1
            }
            location += 1
        }
        return count
    }

    func refreshDirtyState() {
        synchronizeLiveText()
        let currentText = text
        let savedSnapshot = savedText
        updateDirtyState(currentText != savedSnapshot)
    }

    func markSaved() {
        synchronizeLiveText()
        let currentText = text
        savedText = currentText
        updateDirtyState(false)
    }

    func markSaved(snapshot: String, revision: UInt) {
        savedText = snapshot
        let shouldBeDirty = textRevision != revision
            || hasPendingLiveEdits
            || text != snapshot
        updateDirtyState(shouldBeDirty)
    }

    func attachLiveTextProvider(
        id: UUID,
        provider: @escaping () -> String?,
        acknowledgement: @escaping (UInt) -> Void
    ) {
        liveTextProviderID = id
        liveTextProvider = provider
        liveTextAcknowledgement = acknowledgement
    }

    func detachLiveTextProvider(id: UUID) {
        guard liveTextProviderID == id else { return }
        synchronizeLiveText()
        liveTextProviderID = nil
        liveTextProvider = nil
        liveTextAcknowledgement = nil
        hasPendingLiveEdits = false
        pendingLiveTextIsEmpty = nil
        updateDirtyState(text != savedText)
    }

    func noteLiveEdit(isEmpty: Bool) {
        hasPendingLiveEdits = true
        pendingLiveTextIsEmpty = isEmpty
        let shouldBeDirty = !(url == nil && isEmpty)
        updateDirtyState(shouldBeDirty)
    }

    @discardableResult
    func synchronizeLiveText() -> Bool {
        guard hasPendingLiveEdits,
              let currentText = liveTextProvider?() else { return false }
        hasPendingLiveEdits = false
        pendingLiveTextIsEmpty = nil
        text = currentText
        liveTextAcknowledgement?(textRevision)
        return true
    }

    func synchronizedText() -> String {
        synchronizeLiveText()
        return text
    }

    private func updateDirtyState(_ newValue: Bool) {
        guard !isUpdatingDirtyState else { return }
        guard isDirty != newValue else { return }
        isUpdatingDirtyState = true
        defer { isUpdatingDirtyState = false }
        isDirty = newValue
    }

    func updateLocationAfterRename(from oldURL: URL, to newURL: URL) {
        guard url?.standardizedFileURL == oldURL.standardizedFileURL else {
            return
        }
        updateLocation(to: newURL)
    }

    func updateLocation(to newURL: URL) {
        let wasMarkdown = language == .markdown
        let newLanguage = EditorLanguage.infer(from: newURL)
        url = newURL.standardizedFileURL
        language = newLanguage
        if newLanguage == .markdown, !wasMarkdown {
            isPreviewVisible = true
        } else if newLanguage != .markdown {
            isPreviewVisible = false
        }

        // @Published announces before assignment. Emit once after this compound
        // update so parent views read the new title, language, and preview state.
        objectWillChange.send()
    }

    private func scheduleMetricsRefresh() {
        metricsGeneration &+= 1
        let generation = metricsGeneration
        let snapshot = text
        metricsDebounceWorkItem?.cancel()
        metricsDebounceWorkItem = nil
        metricsOperation?.cancel()
        metricsOperation = nil

        guard isWordCountEnabled else {
            wordCount = 0
            return
        }

        if snapshot.utf16.count < 100_000 {
            wordCount = Self.countWords(in: snapshot)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  metricsGeneration == generation else { return }
            metricsDebounceWorkItem = nil
            startMetricsRefresh(for: snapshot, generation: generation)
        }
        metricsDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.4,
            execute: workItem
        )
    }

    private func startMetricsRefresh(
        for snapshot: String,
        generation: UInt
    ) {
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation,
                  !operation.isCancelled,
                  let count = Self.countWords(
                      in: snapshot,
                      isCancelled: { operation.isCancelled }
                  ),
                  !operation.isCancelled else {
                return
            }
            DispatchQueue.main.async {
                guard let self,
                      self.metricsGeneration == generation,
                      !operation.isCancelled else { return }
                self.wordCount = count
                if self.metricsOperation === operation {
                    self.metricsOperation = nil
                }
            }
        }
        metricsOperation = operation
        metricsQueue.addOperation(operation)
    }

    private static func countWords(in text: String) -> Int {
        countWords(in: text, isCancelled: { false }) ?? 0
    }

    private static func countWords(
        in text: String,
        isCancelled: () -> Bool
    ) -> Int? {
        var count = 0
        var scannedCount = 0
        for scalar in text.unicodeScalars {
            if scannedCount.isMultiple(of: 4_096), isCancelled() {
                return nil
            }
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                count += 1
            }
            scannedCount += 1
        }
        return count
    }
}
