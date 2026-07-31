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

    private struct StringDelimiter {
        let value: String
        let allowsBackslashEscapes: Bool
        let allowsDoubledDelimiter: Bool
        let allowsLineBreaks: Bool
    }

    private struct LexicalConfiguration {
        var lineComments: [String] = []
        var lineCommentRequiresBoundary = false
        var blockComment: (start: String, end: String)?
        var strings: [StringDelimiter] = []
        var supportsJavaScriptRegexLiterals = false
    }

    private static let contextPadding = 64 * 1_024

    static func apply(
        to storage: NSTextStorage,
        language: EditorLanguage,
        baseFont: NSFont,
        range requestedRange: NSRange? = nil
    ) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let highlightRange = requestedRange.map {
            NSIntersectionRange($0, fullRange)
        } ?? fullRange
        guard highlightRange.length > 0 else { return }

        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor
        ], range: highlightRange)

        for token in tokens(
            in: storage.string,
            language: language,
            range: highlightRange
        ) {
            let tokenRange = NSIntersectionRange(token.range, highlightRange)
            guard tokenRange.length > 0 else { continue }
            storage.addAttributes(
                attributes(for: token.kind, baseFont: baseFont),
                range: tokenRange
            )
        }
        storage.endEditing()
    }

    static func tokens(
        in string: String,
        language: EditorLanguage,
        range requestedRange: NSRange? = nil
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
            return jsonTokens(in: nsString, range: highlightRange)
        case .html:
            return htmlTokens(in: nsString, range: highlightRange)
        default:
            var result = semanticTokens(
                in: string,
                language: language,
                range: highlightRange
            )
            if let configuration = lexicalConfiguration(for: language) {
                result.append(contentsOf: lexicalTokens(
                    in: nsString,
                    range: contextualRange(in: nsString, around: highlightRange),
                    configuration: configuration
                ))
            }
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
        in string: NSString,
        range: NSRange
    ) -> [Token] {
        var result = semanticTokens(
            in: string as String,
            language: .json,
            range: range
        )
        let strings = lexicalTokens(
            in: string,
            range: contextualRange(in: string, around: range),
            configuration: LexicalConfiguration(strings: [
                StringDelimiter(
                    value: "\"",
                    allowsBackslashEscapes: true,
                    allowsDoubledDelimiter: false,
                    allowsLineBreaks: false
                )
            ])
        )
        result.append(contentsOf: strings)

        for token in strings where token.kind == .string {
            var location = NSMaxRange(token.range)
            while location < string.length,
                  CharacterSet.whitespacesAndNewlines.contains(
                    UnicodeScalar(string.character(at: location))!
                  ) {
                location += 1
            }
            if location < string.length, string.character(at: location) == 0x3A {
                result.append(Token(range: token.range, kind: .property))
            }
        }
        return result
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

            let strings = lexicalTokens(
                in: string,
                range: tagRange,
                configuration: LexicalConfiguration(strings: commonQuotedStrings)
            )
            result.append(contentsOf: strings)
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

    private static func lexicalTokens(
        in string: NSString,
        range: NSRange,
        configuration: LexicalConfiguration
    ) -> [Token] {
        let end = min(string.length, NSMaxRange(range))
        var location = max(0, range.location)
        var result: [Token] = []
        let delimiters = configuration.strings.sorted {
            $0.value.utf16.count > $1.value.utf16.count
        }

        while location < end {
            if let block = configuration.blockComment,
               hasPrefix(block.start, in: string, at: location, limit: end) {
                let contentStart = location + block.start.utf16.count
                let tokenEnd = rangeOf(
                    block.end,
                    in: string,
                    from: contentStart,
                    limit: end
                ).map(NSMaxRange) ?? end
                result.append(Token(
                    range: NSRange(location: location, length: tokenEnd - location),
                    kind: .comment
                ))
                location = tokenEnd
                continue
            }

            if let marker = configuration.lineComments.first(where: {
                hasPrefix($0, in: string, at: location, limit: end)
                    && (!configuration.lineCommentRequiresBoundary
                        || isCommentBoundary(in: string, at: location))
            }) {
                let tokenEnd = lineEnd(
                    in: string,
                    from: location + marker.utf16.count,
                    limit: end
                )
                result.append(Token(
                    range: NSRange(location: location, length: tokenEnd - location),
                    kind: .comment
                ))
                location = tokenEnd
                continue
            }

            if configuration.supportsJavaScriptRegexLiterals,
               string.character(at: location) == 0x2F,
               isJavaScriptRegexStart(
                   in: string,
                   at: location,
                   lowerBound: range.location
               ) {
                let tokenEnd = javascriptRegexEnd(
                    in: string,
                    from: location,
                    limit: end
                )
                result.append(Token(
                    range: NSRange(location: location, length: tokenEnd - location),
                    kind: .string
                ))
                location = tokenEnd
                continue
            }

            if let delimiter = delimiters.first(where: {
                hasPrefix($0.value, in: string, at: location, limit: end)
            }) {
                let tokenEnd = stringEnd(
                    in: string,
                    from: location,
                    limit: end,
                    delimiter: delimiter
                )
                result.append(Token(
                    range: NSRange(location: location, length: tokenEnd - location),
                    kind: .string
                ))
                location = tokenEnd
                continue
            }
            location += 1
        }
        return result
    }

    private static func isJavaScriptRegexStart(
        in string: NSString,
        at location: Int,
        lowerBound: Int
    ) -> Bool {
        var previous = location - 1
        while previous >= lowerBound,
              CharacterSet.whitespacesAndNewlines.contains(
                  UnicodeScalar(string.character(at: previous))!
              ) {
            previous -= 1
        }
        guard previous >= lowerBound else { return true }

        let character = string.character(at: previous)
        if character == 0x2B || character == 0x2D {
            if previous > lowerBound,
               string.character(at: previous - 1) == character {
                return false
            }
            return true
        }

        switch character {
        case 0x28, 0x5B, 0x7B, // ([{
             0x2C, 0x3B, 0x3A, // ,;:
             0x3D, 0x21, 0x3F, // =!?
             0x26, 0x7C,       // &|
             0x2A, 0x25, 0x7E, 0x5E, // *%~^
             0x3C, 0x3E:       // <>
            return true
        default:
            break
        }

        guard isJavaScriptIdentifierCharacter(character) else {
            return false
        }
        var wordStart = previous
        while wordStart > lowerBound,
              isJavaScriptIdentifierCharacter(
                  string.character(at: wordStart - 1)
              ) {
            wordStart -= 1
        }
        let word = string.substring(with: NSRange(
            location: wordStart,
            length: previous - wordStart + 1
        ))
        return javascriptRegexPrefixKeywords.contains(word)
    }

    private static func javascriptRegexEnd(
        in string: NSString,
        from start: Int,
        limit: Int
    ) -> Int {
        var location = start + 1
        var isInsideCharacterClass = false

        while location < limit {
            let character = string.character(at: location)
            if isLineTerminator(character) {
                return location
            }
            if character == 0x5C {
                location = min(limit, location + 2)
                continue
            }
            if character == 0x5B {
                isInsideCharacterClass = true
            } else if character == 0x5D {
                isInsideCharacterClass = false
            } else if character == 0x2F, !isInsideCharacterClass {
                location += 1
                while location < limit,
                      isJavaScriptRegexFlag(string.character(at: location)) {
                    location += 1
                }
                return location
            }
            location += 1
        }
        return limit
    }

    private static func isJavaScriptIdentifierCharacter(
        _ character: unichar
    ) -> Bool {
        (character >= 0x41 && character <= 0x5A)
            || (character >= 0x61 && character <= 0x7A)
            || (character >= 0x30 && character <= 0x39)
            || character == 0x24
            || character == 0x5F
    }

    private static func isJavaScriptRegexFlag(_ character: unichar) -> Bool {
        switch character {
        case 0x64, 0x67, 0x69, 0x6D, 0x73, 0x75, 0x76, 0x79:
            return true
        default:
            return false
        }
    }

    private static func stringEnd(
        in string: NSString,
        from start: Int,
        limit: Int,
        delimiter: StringDelimiter
    ) -> Int {
        let delimiterLength = delimiter.value.utf16.count
        var location = start + delimiterLength
        while location < limit {
            if delimiter.allowsBackslashEscapes,
               string.character(at: location) == 0x5C {
                location = min(limit, location + 2)
                continue
            }
            if !delimiter.allowsLineBreaks,
               isLineTerminator(string.character(at: location)) {
                return location
            }
            if hasPrefix(delimiter.value, in: string, at: location, limit: limit) {
                if delimiter.allowsDoubledDelimiter,
                   hasPrefix(
                    delimiter.value + delimiter.value,
                    in: string,
                    at: location,
                    limit: limit
                   ) {
                    location += delimiterLength * 2
                    continue
                }
                return location + delimiterLength
            }
            location += 1
        }
        return limit
    }

    private static func lineEnd(
        in string: NSString,
        from start: Int,
        limit: Int
    ) -> Int {
        var location = start
        while location < limit {
            if isLineTerminator(string.character(at: location)) {
                return location
            }
            location += 1
        }
        return limit
    }

    private static func isLineTerminator(_ character: unichar) -> Bool {
        character == 0x0A
            || character == 0x0D
            || character == 0x2028
            || character == 0x2029
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

    private static func attributes(
        for kind: TokenKind,
        baseFont: NSFont
    ) -> [NSAttributedString.Key: Any] {
        let color: NSColor
        let font: NSFont
        switch kind {
        case .keyword, .markup, .selector:
            color = Palette.keyword
            font = baseFont
        case .string:
            color = Palette.string
            font = baseFont
        case .number:
            color = Palette.number
            font = baseFont
        case .literal, .function, .typeName, .attribute, .property, .variable:
            color = Palette.symbol
            font = baseFont
        case .punctuation:
            color = NSColor.tertiaryLabelColor
            font = baseFont
        case .comment:
            color = NSColor.secondaryLabelColor
            font = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        case .heading, .strong:
            color = kind == .heading ? Palette.keyword : Palette.symbol
            font = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        case .emphasis:
            color = Palette.symbol
            font = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        }
        return [.foregroundColor: color, .font: font]
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

    private static let commonQuotedStrings = [
        StringDelimiter(
            value: "\"",
            allowsBackslashEscapes: true,
            allowsDoubledDelimiter: false,
            allowsLineBreaks: false
        ),
        StringDelimiter(
            value: "'",
            allowsBackslashEscapes: true,
            allowsDoubledDelimiter: false,
            allowsLineBreaks: false
        )
    ]

    private static func lexicalConfiguration(
        for language: EditorLanguage
    ) -> LexicalConfiguration? {
        switch language {
        case .javascript, .typescript:
            return LexicalConfiguration(
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                strings: commonQuotedStrings + [
                    StringDelimiter(
                        value: "`",
                        allowsBackslashEscapes: true,
                        allowsDoubledDelimiter: false,
                        allowsLineBreaks: true
                    )
                ],
                supportsJavaScriptRegexLiterals: true
            )
        case .css:
            return LexicalConfiguration(
                blockComment: ("/*", "*/"),
                strings: commonQuotedStrings
            )
        case .python:
            return LexicalConfiguration(
                lineComments: ["#"],
                strings: [
                    StringDelimiter(
                        value: "\"\"\"",
                        allowsBackslashEscapes: true,
                        allowsDoubledDelimiter: false,
                        allowsLineBreaks: true
                    ),
                    StringDelimiter(
                        value: "'''",
                        allowsBackslashEscapes: true,
                        allowsDoubledDelimiter: false,
                        allowsLineBreaks: true
                    )
                ] + commonQuotedStrings
            )
        case .swift:
            return LexicalConfiguration(
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                strings: [
                    StringDelimiter(
                        value: "\"\"\"",
                        allowsBackslashEscapes: true,
                        allowsDoubledDelimiter: false,
                        allowsLineBreaks: true
                    ),
                    StringDelimiter(
                        value: "\"",
                        allowsBackslashEscapes: true,
                        allowsDoubledDelimiter: false,
                        allowsLineBreaks: false
                    )
                ]
            )
        case .shell:
            return LexicalConfiguration(
                lineComments: ["#"],
                lineCommentRequiresBoundary: true,
                strings: [
                    StringDelimiter(
                        value: "\"",
                        allowsBackslashEscapes: true,
                        allowsDoubledDelimiter: false,
                        allowsLineBreaks: false
                    ),
                    StringDelimiter(
                        value: "'",
                        allowsBackslashEscapes: false,
                        allowsDoubledDelimiter: false,
                        allowsLineBreaks: false
                    )
                ]
            )
        case .yaml:
            return LexicalConfiguration(
                lineComments: ["#"],
                lineCommentRequiresBoundary: true,
                strings: [
                    StringDelimiter(
                        value: "\"",
                        allowsBackslashEscapes: true,
                        allowsDoubledDelimiter: false,
                        allowsLineBreaks: false
                    ),
                    StringDelimiter(
                        value: "'",
                        allowsBackslashEscapes: false,
                        allowsDoubledDelimiter: true,
                        allowsLineBreaks: false
                    )
                ]
            )
        case .cFamily:
            return LexicalConfiguration(
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                strings: commonQuotedStrings
            )
        case .sql:
            return LexicalConfiguration(
                lineComments: ["--"],
                blockComment: ("/*", "*/"),
                strings: [
                    StringDelimiter(
                        value: "'",
                        allowsBackslashEscapes: false,
                        allowsDoubledDelimiter: true,
                        allowsLineBreaks: false
                    ),
                    StringDelimiter(
                        value: "\"",
                        allowsBackslashEscapes: false,
                        allowsDoubledDelimiter: true,
                        allowsLineBreaks: false
                    )
                ]
            )
        default:
            return nil
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
    private static let javascriptRegexPrefixKeywords: Set<String> = [
        "await",
        "case",
        "delete",
        "do",
        "else",
        "in",
        "instanceof",
        "new",
        "of",
        "return",
        "throw",
        "typeof",
        "void",
        "yield"
    ]
}
