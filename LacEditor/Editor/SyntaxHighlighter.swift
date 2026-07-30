import AppKit

enum SyntaxHighlighter {
    private struct Rule {
        let pattern: String
        let color: NSColor
        var options: NSRegularExpression.Options = []
        var group = 0
        var font: NSFont? = nil
    }

    static func apply(
        to storage: NSTextStorage,
        language: EditorLanguage,
        baseFont: NSFont,
        range requestedRange: NSRange? = nil
    ) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let highlightRange = requestedRange.map { NSIntersectionRange($0, fullRange) } ?? fullRange
        guard highlightRange.length > 0 else { return }
        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor
        ], range: highlightRange)

        for rule in rules(for: language, baseFont: baseFont) {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { continue }
            regex.enumerateMatches(in: storage.string, range: highlightRange) { match, _, _ in
                guard let match else { return }
                let range = match.range(at: rule.group)
                guard range.location != NSNotFound else { return }
                storage.addAttribute(.foregroundColor, value: rule.color, range: range)
                if let font = rule.font {
                    storage.addAttribute(.font, value: font, range: range)
                }
            }
        }
        storage.endEditing()
    }

    private static func rules(for language: EditorLanguage, baseFont: NSFont) -> [Rule] {
        let accent = NSColor.systemIndigo
        let green = NSColor.systemGreen.blended(withFraction: 0.25, of: .labelColor) ?? .systemGreen
        let orange = NSColor.systemOrange.blended(withFraction: 0.25, of: .labelColor) ?? .systemOrange
        let muted = NSColor.secondaryLabelColor
        let violet = NSColor.systemPurple.blended(withFraction: 0.35, of: .labelColor) ?? .systemPurple
        let bold = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        let italic = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)

        switch language {
        case .plainText:
            return []
        case .markdown:
            return [
                Rule(pattern: #"^#{1,6}\s+.*$"#, color: accent, options: .anchorsMatchLines, font: bold),
                Rule(pattern: #"^>\s+.*$"#, color: muted, options: .anchorsMatchLines, font: italic),
                Rule(pattern: #"^(\s*)([-*+]|\d+\.)\s+"#, color: green, options: .anchorsMatchLines),
                Rule(pattern: #"`[^`\n]+`"#, color: orange),
                Rule(pattern: #"(?s)```.*?```"#, color: orange),
                Rule(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#, color: accent),
                Rule(pattern: #"\*\*[^*\n]+\*\*|__[^_\n]+__"#, color: violet, font: bold),
                Rule(pattern: #"(?<!\*)\*[^*\n]+\*(?!\*)|(?<!_)_[^_\n]+_(?!_)"#, color: violet, font: italic)
            ]
        case .json:
            return [
                Rule(pattern: #""(?:\\.|[^"\\])*"\s*:"#, color: accent),
                Rule(pattern: #":\s*("(?:\\.|[^"\\])*")"#, color: green, group: 1),
                Rule(pattern: #"\b-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, color: orange),
                Rule(pattern: #"\b(?:true|false|null)\b"#, color: violet),
                Rule(pattern: #"[\{\}\[\]]"#, color: muted)
            ]
        case .html:
            return [
                Rule(pattern: #"(?s)<!--.*?-->"#, color: muted, font: italic),
                Rule(pattern: #"</?[A-Za-z][^>]*?>"#, color: accent),
                Rule(pattern: #"\s([A-Za-z_:][-A-Za-z0-9_:.]*)(?=\s*=)"#, color: violet, group: 1),
                Rule(pattern: #"("[^"]*"|'[^']*')"#, color: green)
            ]
        case .javascript, .typescript:
            let typeScriptKeywords = language == .typescript
                ? "|abstract|any|as|asserts|bigint|boolean|declare|enum|implements|interface|keyof|namespace|never|number|object|private|protected|public|readonly|required|string|symbol|type|unknown"
                : ""
            return [
                Rule(
                    pattern: "\\b(?:async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|export|extends|finally|for|from|function|get|if|import|in|instanceof|let|new|of|return|set|static|super|switch|this|throw|try|typeof|var|void|while|with|yield\(typeScriptKeywords))\\b",
                    color: accent
                ),
                Rule(pattern: #"\b(?:true|false|null|undefined|NaN|Infinity)\b"#, color: violet),
                Rule(pattern: #"\b(?:0[xX][0-9a-fA-F]+|0[bB][01]+|0[oO][0-7]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)n?\b"#, color: orange),
                Rule(
                    pattern: #"\b(?:function|class)\s+([A-Za-z_$][\w$]*)"#,
                    color: violet,
                    group: 1,
                    font: bold
                ),
                Rule(
                    pattern: #"([A-Za-z_$][\w$]*)\s*(?=\()"#,
                    color: violet,
                    group: 1
                ),
                Rule(
                    pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#,
                    color: green,
                    options: .dotMatchesLineSeparators
                ),
                Rule(
                    pattern: #"/\*.*?\*/|//[^\n]*"#,
                    color: muted,
                    options: .dotMatchesLineSeparators,
                    font: italic
                )
            ]
        case .css:
            return [
                Rule(pattern: #"/\*.*?\*/"#, color: muted, options: .dotMatchesLineSeparators, font: italic),
                Rule(pattern: #"(?m)^[^{@\n][^{\n]*(?=\s*\{)"#, color: accent),
                Rule(pattern: #"(?m)^\s*([-\w]+)(?=\s*:)"#, color: violet, group: 1),
                Rule(pattern: #"#[0-9a-fA-F]{3,8}\b|\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg)?\b"#, color: orange),
                Rule(pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, color: green),
                Rule(pattern: #"(?m)^\s*@[A-Za-z-]+"#, color: violet)
            ]
        case .python:
            return [
                Rule(
                    pattern: #"\b(?:and|as|assert|async|await|break|case|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|match|nonlocal|not|or|pass|raise|return|try|while|with|yield)\b"#,
                    color: accent
                ),
                Rule(pattern: #"\b(?:True|False|None|NotImplemented|Ellipsis)\b"#, color: violet),
                Rule(pattern: #"\b(?:def|class)\s+([A-Za-z_]\w*)"#, color: violet, group: 1, font: bold),
                Rule(pattern: #"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?j?\b"#, color: orange),
                Rule(
                    pattern: #"(?s:""".*?"""|'''.*?''')|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#,
                    color: green
                ),
                Rule(pattern: #"(?m)#.*$"#, color: muted, font: italic)
            ]
        case .swift:
            return [
                Rule(
                    pattern: #"\b(?:actor|as|associatedtype|async|await|break|case|catch|class|continue|convenience|default|defer|deinit|do|else|enum|extension|fallthrough|fileprivate|final|for|func|get|guard|if|import|in|indirect|infix|init|inout|internal|is|isolated|lazy|let|mutating|nonisolated|open|operator|override|private|protocol|public|repeat|required|rethrows|return|self|set|some|static|struct|subscript|super|switch|throws|try|typealias|var|where|while|willSet|didSet)\b"#,
                    color: accent
                ),
                Rule(pattern: #"\b(?:true|false|nil)\b"#, color: violet),
                Rule(pattern: #"\b(?:func|class|struct|enum|protocol)\s+([A-Za-z_]\w*)"#, color: violet, group: 1, font: bold),
                Rule(pattern: #"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, color: orange),
                Rule(pattern: #""(?:\\.|[^"\\])*""#, color: green),
                Rule(pattern: #"/\*.*?\*/|//[^\n]*"#, color: muted, options: .dotMatchesLineSeparators, font: italic)
            ]
        case .shell:
            return [
                Rule(
                    pattern: #"\b(?:case|do|done|elif|else|esac|fi|for|function|if|in|select|then|time|until|while)\b"#,
                    color: accent
                ),
                Rule(pattern: #"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#, color: violet),
                Rule(pattern: #"\b\d+\b"#, color: orange),
                Rule(pattern: #""(?:\\.|[^"\\])*"|'[^']*'"#, color: green),
                Rule(pattern: #"(?m)#.*$"#, color: muted, font: italic)
            ]
        case .yaml:
            return [
                Rule(pattern: #"(?m)^(\s*[-?]?\s*[A-Za-z0-9_.-]+)(?=\s*:)"#, color: accent, group: 1),
                Rule(pattern: #"\b(?:true|false|null|yes|no|on|off|~)\b"#, color: violet, options: .caseInsensitive),
                Rule(pattern: #"\b-?\d+(?:\.\d+)?\b"#, color: orange),
                Rule(pattern: #""(?:\\.|[^"\\])*"|'[^']*'"#, color: green),
                Rule(pattern: #"(?m)#.*$"#, color: muted, font: italic),
                Rule(pattern: #"(?m)^\s*-\s+"#, color: violet)
            ]
        case .cFamily:
            return [
                Rule(
                    pattern: #"\b(?:alignas|alignof|asm|auto|bool|break|case|catch|char|class|const|constexpr|continue|default|delete|do|double|else|enum|explicit|export|extern|false|float|for|friend|if|inline|int|long|namespace|new|nullptr|operator|private|protected|public|register|return|short|signed|sizeof|static|struct|switch|template|this|throw|true|try|typedef|typename|union|unsigned|using|virtual|void|volatile|while)\b"#,
                    color: accent
                ),
                Rule(pattern: #"(?m)^\s*#\s*[A-Za-z]+"#, color: violet),
                Rule(pattern: #"\b(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?)\b"#, color: orange),
                Rule(pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, color: green),
                Rule(pattern: #"/\*.*?\*/|//[^\n]*"#, color: muted, options: .dotMatchesLineSeparators, font: italic)
            ]
        case .sql:
            return [
                Rule(
                    pattern: #"\b(?:add|alter|and|as|asc|begin|between|by|case|commit|create|database|default|delete|desc|distinct|drop|else|end|exists|from|full|group|having|in|index|inner|insert|into|is|join|left|like|limit|not|null|on|or|order|outer|primary|references|right|rollback|select|set|table|then|union|unique|update|values|view|when|where|with)\b"#,
                    color: accent,
                    options: .caseInsensitive
                ),
                Rule(pattern: #"'(?:''|[^'])*'|"(?:\"|[^"])*""#, color: green),
                Rule(pattern: #"\b-?\d+(?:\.\d+)?\b"#, color: orange),
                Rule(pattern: #"\b(?:true|false|null)\b"#, color: violet, options: .caseInsensitive),
                Rule(pattern: #"/\*.*?\*/|--[^\n]*"#, color: muted, options: .dotMatchesLineSeparators, font: italic)
            ]
        }
    }
}
