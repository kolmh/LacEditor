import Combine
import Foundation

enum WorkspaceExitBehavior: String, CaseIterable, Identifiable {
    case preserveWorkspace
    case askToSave

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .preserveWorkspace: "保留工作区并退出"
        case .askToSave: "每次检查未保存文件"
        }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    static let defaultFontSize: CGFloat = 14
    static let defaultLineSpacing = FoldLayoutManager.defaultLineSpacing

    @Published var wordWrapEnabled: Bool {
        didSet { defaults.set(wordWrapEnabled, forKey: Keys.wordWrap) }
    }
    @Published var editorFontSize: CGFloat {
        didSet {
            let clamped = min(max(editorFontSize, 9), 32)
            if clamped != editorFontSize {
                editorFontSize = clamped
                return
            }
            defaults.set(Double(editorFontSize), forKey: Keys.fontSize)
        }
    }
    @Published var editorLineSpacing: CGFloat {
        didSet {
            let clamped = min(max(editorLineSpacing, 0), 10)
            if clamped != editorLineSpacing {
                editorLineSpacing = clamped
                return
            }
            defaults.set(Double(editorLineSpacing), forKey: Keys.lineSpacing)
        }
    }
    @Published var indentationStyle: IndentationStyle {
        didSet { defaults.set(indentationStyle.rawValue, forKey: Keys.indentationStyle) }
    }
    @Published var tabWidth: Int {
        didSet {
            let clamped = [2, 4, 8].contains(tabWidth) ? tabWidth : 4
            if clamped != tabWidth {
                tabWidth = clamped
                return
            }
            defaults.set(tabWidth, forKey: Keys.tabWidth)
        }
    }
    @Published var lineNumbersVisible: Bool {
        didSet { defaults.set(lineNumbersVisible, forKey: Keys.lineNumbers) }
    }
    @Published var statusBarVisible: Bool {
        didSet { defaults.set(statusBarVisible, forKey: Keys.statusBar) }
    }
    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }
    @Published var workspaceExitBehavior: WorkspaceExitBehavior {
        didSet {
            defaults.set(workspaceExitBehavior.rawValue, forKey: Keys.exitBehavior)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        wordWrapEnabled = defaults.object(forKey: Keys.wordWrap) as? Bool ?? true
        let storedFontSize = defaults.object(forKey: Keys.fontSize) as? Double
        editorFontSize = min(
            max(CGFloat(storedFontSize ?? Double(Self.defaultFontSize)), 9),
            32
        )
        let storedLineSpacing = defaults.object(forKey: Keys.lineSpacing) as? Double
        editorLineSpacing = min(
            max(
                CGFloat(storedLineSpacing ?? Double(Self.defaultLineSpacing)),
                0
            ),
            10
        )
        indentationStyle = IndentationStyle(
            rawValue: defaults.string(forKey: Keys.indentationStyle) ?? ""
        ) ?? .spaces
        let storedTabWidth = defaults.integer(forKey: Keys.tabWidth)
        tabWidth = [2, 4, 8].contains(storedTabWidth) ? storedTabWidth : 4
        lineNumbersVisible = defaults.object(forKey: Keys.lineNumbers) as? Bool ?? true
        statusBarVisible = defaults.object(forKey: Keys.statusBar) as? Bool ?? true
        let storedTheme = defaults.string(forKey: Keys.theme)
        theme = AppTheme(rawValue: storedTheme ?? "") ?? .system
        let storedExitBehavior = defaults.string(forKey: Keys.exitBehavior)
        workspaceExitBehavior = WorkspaceExitBehavior(
            rawValue: storedExitBehavior ?? ""
        ) ?? .preserveWorkspace
    }

    var hasConfirmedWorkspaceExitPrompt: Bool {
        defaults.bool(forKey: Keys.confirmedWorkspaceExitPrompt)
    }

    func confirmWorkspaceExitPrompt() {
        defaults.set(true, forKey: Keys.confirmedWorkspaceExitPrompt)
    }

    private enum Keys {
        static let wordWrap = "isWordWrapEnabled"
        static let fontSize = "editorFontSize"
        static let lineSpacing = "editorLineSpacing"
        static let indentationStyle = "editorIndentationStyle"
        static let tabWidth = "editorTabWidth"
        static let lineNumbers = "isLineNumbersVisible"
        static let statusBar = "isStatusBarVisible"
        static let theme = "appTheme"
        static let exitBehavior = "workspaceExitBehavior"
        static let confirmedWorkspaceExitPrompt = "hasConfirmedWorkspaceExitPrompt"
    }
}
