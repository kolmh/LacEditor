import AppKit

enum SyntaxHighlighter {
    enum TokenKind: String {
        case keyword
        case string
        case number
        case literal
        case comment
        case function
        case typeName
        case punctuation
        case markup
        case heading
        case strong
        case emphasis
        case attribute
        case property
        case selector
        case variable
    }

    struct Token: Equatable {
        let range: NSRange
        let kind: TokenKind
    }

    final class IncrementalContext {
        fileprivate let codeLexicalContext = CodeLexicalScanner.IncrementalContext()

        func reset() {
            codeLexicalContext.reset()
        }

        func invalidate(after location: Int) {
            codeLexicalContext.invalidate(after: location)
        }

        var preparedThrough: Int {
            codeLexicalContext.preparedThrough
        }
    }

    private struct RuleDefinition {
        let pattern: String
        let kind: TokenKind
        var options: NSRegularExpression.Options = []
        var group = 0
    }

    private struct CompiledRule {
        let expression: NSRegularExpression
        let kind: TokenKind
        let group: Int
    }

    // HTML 属性字符串仍使用这组轻量扫描类型；代码语言统一由
    // CodeLexicalScanner 管理增量词法状态。
    private static let contextPadding = 64 * 1_024

    static func apply(
        to storage: NSTextStorage,
        language: EditorLanguage,
        baseFont _: NSFont,
        range requestedRange: NSRange? = nil
    ) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let highlightRange = requestedRange.map {
            NSIntersectionRange($0, fullRange)
        } ?? fullRange
        guard highlightRange.length > 0 else { return }

        let tokens = tokens(
            in: storage.string,
            language: language,
            range: highlightRange
        )
        for layoutManager in storage.layoutManagers {
            apply(tokens: tokens, to: layoutManager, range: highlightRange)
        }
    }

    static func apply(
        tokens: [Token],
        to layoutManager: NSLayoutManager?,
        range requestedRange: NSRange
    ) {
        guard let layoutManager,
              let storage = layoutManager.textStorage else { return }
        let highlightRange = NSIntersectionRange(
            requestedRange,
            NSRange(location: 0, length: storage.length)
        )
        guard highlightRange.length > 0 else { return }

        // Syntax is presentation-only. Temporary layout attributes cannot
        // alter the document, typing attributes, paragraph metrics, undo stack,
        // or IME marked text. Removing first also clears stale colors when a
        // token disappears after an edit.
        let updates = {
            layoutManager.removeTemporaryAttribute(
                .foregroundColor,
                forCharacterRange: highlightRange
            )

            for token in tokens {
                let tokenRange = NSIntersectionRange(token.range, highlightRange)
                guard tokenRange.length > 0 else { continue }
                layoutManager.addTemporaryAttribute(
                    .foregroundColor,
                    value: color(for: token.kind),
                    forCharacterRange: tokenRange
                )
            }
        }
        if let editorLayoutManager = layoutManager as? FoldLayoutManager {
            editorLayoutManager.updateTemporaryAttributes(
                in: highlightRange,
                updates
            )
        } else {
            updates()
            layoutManager.invalidateDisplay(forCharacterRange: highlightRange)
        }
    }

    static func tokens(
        in string: String,
        language: EditorLanguage,
        range requestedRange: NSRange? = nil,
        context: IncrementalContext? = nil,
        revision: UInt? = nil,
        isCancelled: () -> Bool = { false }
    ) -> [Token] {
        let nsString = string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let highlightRange = requestedRange.map {
            NSIntersectionRange($0, fullRange)
        } ?? fullRange
        guard highlightRange.length > 0 else { return [] }

        switch language {
        case .plainText:
            return []
        case .markdown:
            return markdownTokens(in: nsString, range: highlightRange)
        case .json:
            return jsonTokens(
                in: string,
                range: highlightRange,
                context: context?.codeLexicalContext,
                revision: revision,
                isCancelled: isCancelled
            )
        case .html:
            return htmlTokens(in: nsString, range: highlightRange)
        default:
            var result = semanticTokens(
                in: string,
                language: language,
                range: highlightRange
            )
            result.append(contentsOf: CodeLexicalScanner.tokens(
                in: string,
                language: language,
                range: highlightRange,
                context: context?.codeLexicalContext,
                revision: revision,
                isCancelled: isCancelled
            ).map(syntaxToken))
            return result
        }
    }

    private static func markdownTokens(
        in string: NSString,
        range: NSRange
    ) -> [Token] {
        var result = semanticTokens(
            in: string as String,
            language: .markdown,
            range: range
        )
        let scanRange = contextualRange(in: string, around: range)
        let fenced = matches(
            expression: markdownFenceExpression,
            in: string as String,
            range: scanRange,
            kind: .string
        )
        result.append(contentsOf: fenced)

        let fencedRanges = fenced.map(\.range)
        let inline = matches(
            expression: markdownInlineCodeExpression,
            in: string as String,
            range: scanRange,
            kind: .string
        ).filter { token in
            !fencedRanges.contains(where: { NSIntersectionRange($0, token.range).length > 0 })
        }
        result.append(contentsOf: inline)
        return result
    }

    private static func jsonTokens(
        in source: String,
        range: NSRange,
        context: CodeLexicalScanner.IncrementalContext?,
        revision: UInt?,
        isCancelled: () -> Bool
    ) -> [Token] {
        let string = source as NSString
        var result = semanticTokens(
            in: source,
            language: .json,
            range: range
        )
        let strings = CodeLexicalScanner.tokens(
            in: source,
            language: .json,
            range: range,
            context: context,
            revision: revision,
            isCancelled: isCancelled
        ).map(syntaxToken)
        result.append(contentsOf: strings)

        for token in strings where token.kind == .string {
            var location = NSMaxRange(token.range)
            while location < string.length,
                  isWhitespace(string.character(at: location)) {
                location += 1
            }
            if location < string.length, string.character(at: location) == 0x3A {
                result.append(Token(range: token.range, kind: .property))
            }
        }
        return result
    }

    private static func syntaxToken(
        _ token: CodeLexicalScanner.Token
    ) -> Token {
        Token(
            range: token.range,
            kind: token.kind == .comment ? .comment : .string
        )
    }

    private static func htmlTokens(
        in string: NSString,
        range: NSRange
    ) -> [Token] {
        let scanRange = contextualRange(in: string, around: range)
        let end = NSMaxRange(scanRange)
        var location = scanRange.location
        var result: [Token] = []

        while location < end {
            if hasPrefix("<!--", in: string, at: location, limit: end) {
                let commentEnd = rangeOf(
                    "-->",
                    in: string,
                    from: location + 4,
                    limit: end
                ).map(NSMaxRange) ?? end
                result.append(Token(
                    range: NSRange(location: location, length: commentEnd - location),
                    kind: .comment
                ))
                location = commentEnd
                continue
            }

            guard string.character(at: location) == 0x3C,
                  isHTMLTagStart(in: string, at: location, limit: end),
                  let tagEnd = htmlTagEnd(in: string, from: location, limit: end)
            else {
                location += 1
                continue
            }

            let tagRange = NSRange(location: location, length: tagEnd - location)
            result.append(Token(range: tagRange, kind: .markup))

            let tagText = string.substring(with: tagRange)
            if let nameMatch = htmlTagNameExpression.firstMatch(
                in: tagText,
                range: NSRange(location: 0, length: (tagText as NSString).length)
            ) {
                let nameRange = nameMatch.range(at: 1)
                if nameRange.location != NSNotFound {
                    result.append(Token(
                        range: NSRange(
                            location: tagRange.location + nameRange.location,
                            length: nameRange.length
                        ),
                        kind: .heading
                    ))
                }
            }

            for match in htmlAttributeExpression.matches(
                in: tagText,
                range: NSRange(location: 0, length: (tagText as NSString).length)
            ) {
                let attributeRange = match.range(at: 1)
                guard attributeRange.location != NSNotFound else { continue }
                result.append(Token(
                    range: NSRange(
                        location: tagRange.location + attributeRange.location,
                        length: attributeRange.length
                    ),
                    kind: .attribute
                ))
            }

            result.append(contentsOf: CodeLexicalScanner.tokens(
                in: string as String,
                language: .html,
                range: tagRange
            ).map(syntaxToken))
            location = tagEnd
        }
        return result
    }

    private static func semanticTokens(
        in string: String,
        language: EditorLanguage,
        range: NSRange
    ) -> [Token] {
        guard let rules = compiledRules[language] else { return [] }
        var result: [Token] = []
        for rule in rules {
            result.append(contentsOf: matches(
                expression: rule.expression,
                in: string,
                range: range,
                kind: rule.kind,
                group: rule.group
            ))
        }
        return result
    }

    private static func contextualRange(
        in string: NSString,
        around range: NSRange
    ) -> NSRange {
        let tentativeStart = max(0, range.location - contextPadding)
        let lineRange = string.lineRange(for: NSRange(
            location: tentativeStart,
            length: 0
        ))
        let end = min(string.length, NSMaxRange(range) + contextPadding)
        return NSRange(
            location: lineRange.location,
            length: max(0, end - lineRange.location)
        )
    }

    private static func isWhitespace(_ codeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(codeUnit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func matches(
        expression: NSRegularExpression,
        in string: String,
        range: NSRange,
        kind: TokenKind,
        group: Int = 0
    ) -> [Token] {
        expression.matches(in: string, range: range).compactMap { match in
            let matchRange = match.range(at: group)
            guard matchRange.location != NSNotFound else { return nil }
            return Token(range: matchRange, kind: kind)
        }
    }

    private static func hasPrefix(
        _ prefix: String,
        in string: NSString,
        at location: Int,
        limit: Int
    ) -> Bool {
        let length = prefix.utf16.count
        guard location >= 0, location + length <= limit else { return false }
        return string.compare(
            prefix,
            options: [],
            range: NSRange(location: location, length: length)
        ) == .orderedSame
    }

    private static func rangeOf(
        _ value: String,
        in string: NSString,
        from location: Int,
        limit: Int
    ) -> NSRange? {
        guard location < limit else { return nil }
        let range = string.range(
            of: value,
            options: [],
            range: NSRange(location: location, length: limit - location)
        )
        return range.location == NSNotFound ? nil : range
    }

    private static func isCommentBoundary(
        in string: NSString,
        at location: Int
    ) -> Bool {
        guard location > 0 else { return true }
        let previous = string.character(at: location - 1)
        return previous == 0x20
            || previous == 0x09
            || previous == 0x0A
            || previous == 0x0D
            || previous == 0x3B
    }

    private static func isHTMLTagStart(
        in string: NSString,
        at location: Int,
        limit: Int
    ) -> Bool {
        guard location + 1 < limit else { return false }
        var next = string.character(at: location + 1)
        if next == 0x2F {
            guard location + 2 < limit else { return false }
            next = string.character(at: location + 2)
        }
        return next == 0x21
            || next == 0x3F
            || (next >= 0x41 && next <= 0x5A)
            || (next >= 0x61 && next <= 0x7A)
    }

    private static func htmlTagEnd(
        in string: NSString,
        from start: Int,
        limit: Int
    ) -> Int? {
        var quote: unichar?
        var location = start + 1
        while location < limit {
            let character = string.character(at: location)
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if character == 0x5C {
                    location += 1
                }
            } else if character == 0x22 || character == 0x27 {
                quote = character
            } else if character == 0x3E {
                return location + 1
            }
            location += 1
        }
        return nil
    }

    private static func color(for kind: TokenKind) -> NSColor {
        let color: NSColor
        switch kind {
        case .keyword, .markup, .selector:
            color = Palette.keyword
        case .string:
            color = Palette.string
        case .number:
            color = Palette.number
        case .literal, .function, .typeName, .attribute, .property, .variable:
            color = Palette.symbol
        case .punctuation:
            color = NSColor.tertiaryLabelColor
        case .comment:
            color = NSColor.secondaryLabelColor
        case .heading, .strong:
            color = kind == .heading ? Palette.keyword : Palette.symbol
        case .emphasis:
            color = Palette.symbol
        }
        return color
    }

    private enum Palette {
        static let keyword = adaptive(
            light: (0.29, 0.31, 0.62),
            dark: (0.62, 0.67, 0.98)
        )
        static let string = adaptive(
            light: (0.20, 0.46, 0.29),
            dark: (0.48, 0.76, 0.55)
        )
        static let number = adaptive(
            light: (0.68, 0.34, 0.10),
            dark: (0.94, 0.62, 0.34)
        )
        static let symbol = adaptive(
            light: (0.53, 0.28, 0.61),
            dark: (0.80, 0.59, 0.88)
        )

        private static func adaptive(
            light: (CGFloat, CGFloat, CGFloat),
            dark: (CGFloat, CGFloat, CGFloat)
        ) -> NSColor {
            NSColor(name: nil) { appearance in
                let values = appearance.bestMatch(from: [.darkAqua, .aqua])
                    == .darkAqua ? dark : light
                return NSColor(
                    calibratedRed: values.0,
                    green: values.1,
                    blue: values.2,
                    alpha: 1
                )
            }
        }
    }

    private static let compiledRules: [EditorLanguage: [CompiledRule]] = {
        Dictionary(uniqueKeysWithValues: EditorLanguage.allCases.map { language in
            let rules: [CompiledRule] = ruleDefinitions(for: language).compactMap { definition in
                guard let expression = try? NSRegularExpression(
                    pattern: definition.pattern,
                    options: definition.options
                ) else {
                    return nil
                }
                return CompiledRule(
                    expression: expression,
                    kind: definition.kind,
                    group: definition.group
                )
            }
            return (language, rules)
        })
    }()

    private static func ruleDefinitions(
        for language: EditorLanguage
    ) -> [RuleDefinition] {
        switch language {
        case .plainText, .html:
            return []
        case .markdown:
            return [
                RuleDefinition(
                    pattern: #"^#{1,6}\s+.*$"#,
                    kind: .heading,
                    options: .anchorsMatchLines
                ),
                RuleDefinition(
                    pattern: #"^>\s+.*$"#,
                    kind: .emphasis,
                    options: .anchorsMatchLines
                ),
                RuleDefinition(
                    pattern: #"^(\s*)([-*+]|\d+[.)])\s+"#,
                    kind: .markup,
                    options: .anchorsMatchLines
                ),
                RuleDefinition(
                    pattern: #"\[([^\]]+)\]\(([^)]+)\)"#,
                    kind: .keyword
                ),
                RuleDefinition(
                    pattern: #"\*\*[^*\n]+\*\*|__[^_\n]+__"#,
                    kind: .strong
                ),
                RuleDefinition(
                    pattern: #"(?<!\*)\*[^*\n]+\*(?!\*)|(?<!_)_[^_\n]+_(?!_)"#,
                    kind: .emphasis
                )
            ]
        case .json:
            return [
                RuleDefinition(
                    pattern: #"\b-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#,
                    kind: .number
                ),
                RuleDefinition(
                    pattern: #"\b(?:true|false|null)\b"#,
                    kind: .literal
                ),
                RuleDefinition(pattern: #"[\{\}\[\]]"#, kind: .punctuation)
            ]
        case .javascript, .typescript:
            let typeScriptKeywords = language == .typescript
                ? "|abstract|any|as|asserts|bigint|boolean|declare|enum|implements|interface|keyof|namespace|never|number|object|private|protected|public|readonly|required|string|symbol|type|unknown"
                : ""
            return [
                RuleDefinition(
                    pattern: #"([A-Za-z_$][\w$]*)\s*(?=\()"#,
                    kind: .function,
                    group: 1
                ),
                RuleDefinition(
                    pattern: #"\b(?:function|class)\s+([A-Za-z_$][\w$]*)"#,
                    kind: .typeName,
                    group: 1
                ),
                RuleDefinition(
                    pattern: #"\b(?:0[xX][0-9a-fA-F]+|0[bB][01]+|0[oO][0-7]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)n?\b"#,
                    kind: .number
                ),
                RuleDefinition(
                    pattern: #"\b(?:true|false|null|undefined|NaN|Infinity)\b"#,
                    kind: .literal
                ),
                RuleDefinition(
                    pattern: "\\b(?:async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|export|extends|finally|for|from|function|get|if|import|in|instanceof|let|new|of|return|set|static|super|switch|this|throw|try|typeof|var|void|while|with|yield\(typeScriptKeywords))\\b",
                    kind: .keyword
                )
            ]
        case .css:
            return [
                RuleDefinition(
                    pattern: #"(?m)^[^{@\n][^{\n]*(?=\s*\{)"#,
                    kind: .selector
                ),
                RuleDefinition(
                    pattern: #"(?m)^\s*([-\w]+)(?=\s*:)"#,
                    kind: .property,
                    group: 1
                ),
                RuleDefinition(
                    pattern: #"#[0-9a-fA-F]{3,8}\b|\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg)?\b"#,
                    kind: .number
                ),
                RuleDefinition(
                    pattern: #"(?m)^\s*@[A-Za-z-]+"#,
                    kind: .keyword
                )
            ]
        case .python:
            return [
                RuleDefinition(
                    pattern: #"\b(?:def|class)\s+([A-Za-z_]\w*)"#,
                    kind: .typeName,
                    group: 1
                ),
                RuleDefinition(
                    pattern: #"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?j?\b"#,
                    kind: .number
                ),
                RuleDefinition(
                    pattern: #"\b(?:True|False|None|NotImplemented|Ellipsis)\b"#,
                    kind: .literal
                ),
                RuleDefinition(
                    pattern: #"\b(?:and|as|assert|async|await|break|case|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|match|nonlocal|not|or|pass|raise|return|try|while|with|yield)\b"#,
                    kind: .keyword
                )
            ]
        case .swift:
            return [
                RuleDefinition(
                    pattern: #"\b(?:func|class|struct|enum|protocol)\s+([A-Za-z_]\w*)"#,
                    kind: .typeName,
                    group: 1
                ),
                RuleDefinition(
                    pattern: #"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#,
                    kind: .number
                ),
                RuleDefinition(pattern: #"\b(?:true|false|nil)\b"#, kind: .literal),
                RuleDefinition(
                    pattern: #"\b(?:actor|as|associatedtype|async|await|break|case|catch|class|continue|convenience|default|defer|deinit|do|else|enum|extension|fallthrough|fileprivate|final|for|func|get|guard|if|import|in|indirect|infix|init|inout|internal|is|isolated|lazy|let|mutating|nonisolated|open|operator|override|private|protocol|public|repeat|required|rethrows|return|self|set|some|static|struct|subscript|super|switch|throws|try|typealias|var|where|while|willSet|didSet)\b"#,
                    kind: .keyword
                )
            ]
        case .shell:
            return [
                RuleDefinition(
                    pattern: #"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#,
                    kind: .variable
                ),
                RuleDefinition(pattern: #"\b\d+\b"#, kind: .number),
                RuleDefinition(
                    pattern: #"\b(?:case|do|done|elif|else|esac|fi|for|function|if|in|select|then|time|until|while)\b"#,
                    kind: .keyword
                )
            ]
        case .yaml:
            return [
                RuleDefinition(
                    pattern: #"(?m)^(\s*[-?]?\s*[A-Za-z0-9_.-]+)(?=\s*:)"#,
                    kind: .property,
                    group: 1
                ),
                RuleDefinition(pattern: #"(?m)^\s*-\s+"#, kind: .markup),
                RuleDefinition(pattern: #"\b-?\d+(?:\.\d+)?\b"#, kind: .number),
                RuleDefinition(
                    pattern: #"\b(?:true|false|null|yes|no|on|off|~)\b"#,
                    kind: .literal,
                    options: .caseInsensitive
                )
            ]
        case .cFamily:
            return [
                RuleDefinition(
                    pattern: #"(?m)^\s*#\s*[A-Za-z]+"#,
                    kind: .keyword
                ),
                RuleDefinition(
                    pattern: #"\b(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?)\b"#,
                    kind: .number
                ),
                RuleDefinition(
                    pattern: #"\b(?:alignas|alignof|asm|auto|bool|break|case|catch|char|class|const|constexpr|continue|default|delete|do|double|else|enum|explicit|export|extern|false|float|for|friend|if|inline|int|long|namespace|new|nullptr|operator|private|protected|public|register|return|short|signed|sizeof|static|struct|switch|template|this|throw|true|try|typedef|typename|union|unsigned|using|virtual|void|volatile|while)\b"#,
                    kind: .keyword
                )
            ]
        case .sql:
            return [
                RuleDefinition(pattern: #"\b-?\d+(?:\.\d+)?\b"#, kind: .number),
                RuleDefinition(
                    pattern: #"\b(?:true|false|null)\b"#,
                    kind: .literal,
                    options: .caseInsensitive
                ),
                RuleDefinition(
                    pattern: #"\b(?:add|alter|and|as|asc|begin|between|by|case|commit|create|database|default|delete|desc|distinct|drop|else|end|exists|from|full|group|having|in|index|inner|insert|into|is|join|left|like|limit|not|null|on|or|order|outer|primary|references|right|rollback|select|set|table|then|union|unique|update|values|view|when|where|with)\b"#,
                    kind: .keyword,
                    options: .caseInsensitive
                )
            ]
        }
    }

    private static let markdownFenceExpression = try! NSRegularExpression(
        pattern: #"(?s)```.*?(?:```|\z)"#
    )
    private static let markdownInlineCodeExpression = try! NSRegularExpression(
        pattern: #"`[^`\n]+`"#
    )
    private static let htmlTagNameExpression = try! NSRegularExpression(
        pattern: #"^</?\s*([A-Za-z][A-Za-z0-9:-]*)"#
    )
    private static let htmlAttributeExpression = try! NSRegularExpression(
        pattern: #"\s([A-Za-z_:][-A-Za-z0-9_:.]*)(?=\s*(?:=|/?>))"#
    )

}
