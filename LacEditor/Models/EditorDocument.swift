import Foundation

final class EditorDocument: ObservableObject, Identifiable {
    let id = UUID()
    @Published var text: String {
        didSet {
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
    @Published private(set) var wordCount: Int
    private(set) var textRevision: UInt = 0
    private var savedText: String
    private var metricsGeneration: UInt = 0
    private let metricsQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private var metricsOperation: BlockOperation?

    init(
        text: String = "",
        url: URL? = nil,
        language: EditorLanguage = .plainText,
        encodingName: String = "UTF-8",
        isDirty: Bool = false
    ) {
        self.text = text
        self.url = url
        self.language = language
        self.encodingName = encodingName
        self.isDirty = isDirty
        self.isPreviewVisible = language == .markdown
        self.savedText = text
        self.wordCount = text.utf16.count < 100_000
            ? Self.countWords(in: text)
            : 0
        if text.utf16.count >= 100_000 {
            scheduleMetricsRefresh()
        }
    }

    deinit {
        metricsOperation?.cancel()
        metricsQueue.cancelAllOperations()
    }

    var displayName: String {
        url?.lastPathComponent ?? "未命名"
    }

    var isDisposableBlank: Bool {
        url == nil && text.isEmpty && !isDirty
    }

    var lineCount: Int {
        max(1, text.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        })
    }

    func refreshDirtyState() {
        isDirty = text != savedText
    }

    func markSaved() {
        savedText = text
        isDirty = false
    }

    private func scheduleMetricsRefresh() {
        metricsGeneration &+= 1
        let generation = metricsGeneration
        let snapshot = text
        metricsOperation?.cancel()

        if snapshot.utf16.count < 100_000 {
            wordCount = Self.countWords(in: snapshot)
            return
        }

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
