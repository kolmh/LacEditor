import Foundation

final class EditorDocument: ObservableObject, Identifiable {
    let id = UUID()
    @Published var text: String
    @Published var url: URL?
    @Published var language: EditorLanguage
    @Published var encodingName: String
    @Published var isDirty: Bool
    @Published var cursorLine = 1
    @Published var cursorColumn = 1
    @Published var selectionRange = NSRange(location: 0, length: 0)
    @Published var statusMessage: String?
    @Published var isPreviewVisible: Bool
    private var savedText: String

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
    }

    var displayName: String {
        url?.lastPathComponent ?? "未命名"
    }

    var isDisposableBlank: Bool {
        url == nil && text.isEmpty && !isDirty
    }

    var wordCount: Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                count += 1
            }
        }
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
}
