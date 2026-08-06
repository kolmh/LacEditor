import Combine
import Foundation

@MainActor
final class AppPreferences: ObservableObject {
    static let defaultFontSize: CGFloat = 14

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
    @Published var lineNumbersVisible: Bool {
        didSet { defaults.set(lineNumbersVisible, forKey: Keys.lineNumbers) }
    }
    @Published var statusBarVisible: Bool {
        didSet { defaults.set(statusBarVisible, forKey: Keys.statusBar) }
    }
    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
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
        lineNumbersVisible = defaults.object(forKey: Keys.lineNumbers) as? Bool ?? true
        statusBarVisible = defaults.object(forKey: Keys.statusBar) as? Bool ?? true
        let storedTheme = defaults.string(forKey: Keys.theme)
        theme = AppTheme(rawValue: storedTheme ?? "") ?? .system
    }

    private enum Keys {
        static let wordWrap = "isWordWrapEnabled"
        static let fontSize = "editorFontSize"
        static let lineNumbers = "isLineNumbersVisible"
        static let statusBar = "isStatusBarVisible"
        static let theme = "appTheme"
    }
}
