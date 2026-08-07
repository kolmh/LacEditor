import Foundation

enum CodeLexicalScanner {
    enum TokenKind {
        case string
        case comment
    }

    struct Token: Equatable {
        let range: NSRange
        let kind: TokenKind
    }

    struct StringDelimiter {
        let value: String
        let allowsBackslashEscapes: Bool
        let allowsDoubledDelimiter: Bool
        let allowsLineBreaks: Bool
    }

    struct Configuration {
        var lineComments: [String] = []
        var lineCommentRequiresBoundary = false
        var blockComment: (start: String, end: String)?
        var strings: [StringDelimiter] = []
        var supportsJavaScriptRegexLiterals = false
    }

    enum State: Equatable {
        case normal
        case lineComment
        case blockComment
        case string(Int)
        case javascriptRegex(Bool)
    }

    fileprivate struct Checkpoint {
        let location: Int
        let state: State
        let lineStart: Int
    }

    final class IncrementalContext {
        private let lock = NSLock()
        private var language: EditorLanguage?
        private var revision: UInt?
        private var checkpoints = [Checkpoint(location: 0, state: .normal, lineStart: 0)]
        private var generation: UInt = 0
        private var acceptsRevisionChange = false

        func reset() {
            lock.lock()
            resetLocked()
            lock.unlock()
        }

        func invalidate(after location: Int) {
            lock.lock()
            generation &+= 1
            checkpoints.removeAll { $0.location > max(0, location) }
            if checkpoints.isEmpty {
                checkpoints = [Checkpoint(location: 0, state: .normal, lineStart: 0)]
            }
            acceptsRevisionChange = true
            lock.unlock()
        }

        var preparedThrough: Int {
            lock.lock()
            defer { lock.unlock() }
            return checkpoints.last?.location ?? 0
        }

        fileprivate func preparation(
            language newLanguage: EditorLanguage,
            revision newRevision: UInt,
            targetLocation: Int
        ) -> (checkpoint: Checkpoint, generation: UInt) {
            lock.lock()
            defer { lock.unlock() }
            if language != newLanguage {
                resetLocked()
                language = newLanguage
                revision = newRevision
            } else if revision != newRevision {
                if acceptsRevisionChange {
                    revision = newRevision
                    acceptsRevisionChange = false
                } else {
                    resetLocked()
                    language = newLanguage
                    revision = newRevision
                }
            }
            let checkpoint = checkpoints.last(where: {
                $0.location <= targetLocation
            }) ?? Checkpoint(location: 0, state: .normal, lineStart: 0)
            return (checkpoint, generation)
        }

        fileprivate func commit(
            _ newCheckpoints: [Checkpoint],
            language expectedLanguage: EditorLanguage,
            revision expectedRevision: UInt,
            generation expectedGeneration: UInt
        ) {
            guard !newCheckpoints.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            guard language == expectedLanguage,
                  revision == expectedRevision,
                  generation == expectedGeneration else { return }
            var byLocation = Dictionary(
                uniqueKeysWithValues: checkpoints.map { ($0.location, $0) }
            )
            for checkpoint in newCheckpoints {
                byLocation[checkpoint.location] = checkpoint
            }
            checkpoints = byLocation.values.sorted { $0.location < $1.location }
        }

        private func resetLocked() {
            generation &+= 1
            language = nil
            revision = nil
            checkpoints = [Checkpoint(location: 0, state: .normal, lineStart: 0)]
            acceptsRevisionChange = false
        }
    }

    private struct ScanResult {
        let tokens: [Token]
        let checkpoints: [Checkpoint]
        let wasCancelled: Bool
    }

    private static let checkpointStride = 16 * 1_024

    static func supports(_ language: EditorLanguage) -> Bool {
        switch language {
        case .json, .javascript, .typescript, .css, .python, .swift,
             .shell, .yaml, .cFamily, .sql:
            true
        case .plainText, .markdown, .html:
            false
        }
    }

    static func tokens(
        in text: String,
        language: EditorLanguage,
        range requestedRange: NSRange,
        context: IncrementalContext? = nil,
        revision: UInt? = nil,
        isCancelled: () -> Bool = { false }
    ) -> [Token] {
        guard let configuration = configuration(for: language) else { return [] }
        let string = text as NSString
        let range = NSIntersectionRange(
            requestedRange,
            NSRange(location: 0, length: string.length)
        )
        guard range.length > 0 else { return [] }

        guard let context, let revision else {
            return scan(
                in: string,
                scanRange: range,
                emissionRange: range,
                configuration: configuration,
                initialState: .normal,
                isCancelled: isCancelled
            ).tokens
        }

        let preparation = context.preparation(
            language: language,
            revision: revision,
            targetLocation: range.location
        )
        let scan = scan(
            in: string,
            scanRange: NSRange(
                location: preparation.checkpoint.location,
                length: string.length - preparation.checkpoint.location
            ),
            emissionRange: range,
            configuration: configuration,
            initialState: preparation.checkpoint.state,
            initialLineStart: preparation.checkpoint.lineStart,
            stopAfter: min(string.length, NSMaxRange(range) + checkpointStride),
            isCancelled: isCancelled
        )
        context.commit(
            scan.checkpoints,
            language: language,
            revision: revision,
            generation: preparation.generation
        )
        guard !scan.wasCancelled else { return [] }
        return scan.tokens
    }

    static func configuration(for language: EditorLanguage) -> Configuration? {
        switch language {
        case .html:
            return Configuration(strings: commonQuotedStrings)
        case .json:
            return Configuration(strings: [doubleQuotedString])
        case .javascript, .typescript:
            return Configuration(
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
            return Configuration(
                blockComment: ("/*", "*/"),
                strings: commonQuotedStrings
            )
        case .python:
            return Configuration(
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
            return Configuration(
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                strings: [
                    StringDelimiter(
                        value: "\"\"\"",
                        allowsBackslashEscapes: true,
                        allowsDoubledDelimiter: false,
                        allowsLineBreaks: true
                    ),
                    doubleQuotedString
                ]
            )
        case .shell:
            return Configuration(
                lineComments: ["#"],
                lineCommentRequiresBoundary: true,
                strings: [
                    doubleQuotedString,
                    StringDelimiter(
                        value: "'",
                        allowsBackslashEscapes: false,
                        allowsDoubledDelimiter: false,
                        allowsLineBreaks: false
                    )
                ]
            )
        case .yaml:
            return Configuration(
                lineComments: ["#"],
                lineCommentRequiresBoundary: true,
                strings: [
                    doubleQuotedString,
                    StringDelimiter(
                        value: "'",
                        allowsBackslashEscapes: false,
                        allowsDoubledDelimiter: true,
                        allowsLineBreaks: false
                    )
                ]
            )
        case .cFamily:
            return Configuration(
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                strings: commonQuotedStrings
            )
        case .sql:
            return Configuration(
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

    private static let doubleQuotedString = StringDelimiter(
        value: "\"",
        allowsBackslashEscapes: true,
        allowsDoubledDelimiter: false,
        allowsLineBreaks: false
    )

    private static let commonQuotedStrings = [
        doubleQuotedString,
        StringDelimiter(
            value: "'",
            allowsBackslashEscapes: true,
            allowsDoubledDelimiter: false,
            allowsLineBreaks: false
        )
    ]

    private static func scan(
        in string: NSString,
        scanRange: NSRange,
        emissionRange: NSRange,
        configuration: Configuration,
        initialState: State,
        initialLineStart: Int? = nil,
        stopAfter: Int? = nil,
        isCancelled: () -> Bool
    ) -> ScanResult {
        let end = min(string.length, stopAfter ?? NSMaxRange(scanRange))
        var location = max(0, scanRange.location)
        var lineStart = min(location, max(0, initialLineStart ?? location))
        var state = initialState
        var tokenStart: Int? = state == .normal ? nil : location
        var result: [Token] = []
        var checkpoints: [Checkpoint] = []
        var lastCheckpointLocation = location
        var scannedCharacters = 0
        let delimiters = configuration.strings.sorted {
            $0.value.utf16.count > $1.value.utf16.count
        }

        func emit(_ start: Int, _ tokenEnd: Int, _ kind: TokenKind) {
            let range = NSRange(location: start, length: max(0, tokenEnd - start))
            if NSIntersectionRange(range, emissionRange).length > 0 {
                result.append(Token(range: range, kind: kind))
            }
        }

        func checkpointIfNeeded() {
            guard location - lastCheckpointLocation >= checkpointStride else { return }
            checkpoints.append(Checkpoint(
                location: location,
                state: state,
                lineStart: lineStart
            ))
            lastCheckpointLocation = location
        }

        func advanceLineBreak() {
            if string.character(at: location) == 0x0D,
               location + 1 < string.length,
               string.character(at: location + 1) == 0x0A {
                location += 2
            } else {
                location += 1
            }
            lineStart = location
            checkpointIfNeeded()
        }

        while location < end {
            if scannedCharacters.isMultiple(of: 4_096), isCancelled() {
                if checkpoints.last?.location != location {
                    checkpoints.append(Checkpoint(
                        location: location,
                        state: state,
                        lineStart: lineStart
                    ))
                }
                return ScanResult(
                    tokens: [],
                    checkpoints: checkpoints,
                    wasCancelled: true
                )
            }
            scannedCharacters += 1

            switch state {
            case .normal:
                if let block = configuration.blockComment,
                   hasPrefix(block.start, in: string, at: location, limit: end) {
                    tokenStart = location
                    state = .blockComment
                    location += block.start.utf16.count
                } else if let marker = configuration.lineComments.first(where: {
                    hasPrefix($0, in: string, at: location, limit: end)
                        && (!configuration.lineCommentRequiresBoundary
                            || isCommentBoundary(in: string, at: location))
                }) {
                    tokenStart = location
                    state = .lineComment
                    location += marker.utf16.count
                } else if configuration.supportsJavaScriptRegexLiterals,
                          string.character(at: location) == 0x2F,
                          isJavaScriptRegexStart(
                            in: string,
                            at: location,
                            lowerBound: lineStart
                          ) {
                    tokenStart = location
                    state = .javascriptRegex(false)
                    location += 1
                } else if let index = delimiters.firstIndex(where: {
                    hasPrefix($0.value, in: string, at: location, limit: end)
                }) {
                    tokenStart = location
                    state = .string(index)
                    location += delimiters[index].value.utf16.count
                } else if isLineTerminator(string.character(at: location)) {
                    advanceLineBreak()
                } else {
                    location += 1
                }

            case .lineComment:
                if isLineTerminator(string.character(at: location)) {
                    emit(tokenStart ?? scanRange.location, location, .comment)
                    tokenStart = nil
                    state = .normal
                } else {
                    location += 1
                }

            case .blockComment:
                if let block = configuration.blockComment,
                   hasPrefix(block.end, in: string, at: location, limit: end) {
                    location += block.end.utf16.count
                    emit(tokenStart ?? scanRange.location, location, .comment)
                    tokenStart = nil
                    state = .normal
                } else if isLineTerminator(string.character(at: location)) {
                    advanceLineBreak()
                } else {
                    location += 1
                }

            case let .string(index):
                let delimiter = delimiters[index]
                let delimiterLength = delimiter.value.utf16.count
                if delimiter.allowsBackslashEscapes,
                   string.character(at: location) == 0x5C {
                    if location + 1 < end,
                       isLineTerminator(string.character(at: location + 1)) {
                        location += 1
                        advanceLineBreak()
                    } else {
                        location = min(end, location + 2)
                    }
                } else if !delimiter.allowsLineBreaks,
                          isLineTerminator(string.character(at: location)) {
                    emit(tokenStart ?? scanRange.location, location, .string)
                    tokenStart = nil
                    state = .normal
                } else if hasPrefix(
                    delimiter.value,
                    in: string,
                    at: location,
                    limit: end
                ) {
                    if delimiter.allowsDoubledDelimiter,
                       hasPrefix(
                        delimiter.value + delimiter.value,
                        in: string,
                        at: location,
                        limit: end
                       ) {
                        location += delimiterLength * 2
                    } else {
                        location += delimiterLength
                        emit(tokenStart ?? scanRange.location, location, .string)
                        tokenStart = nil
                        state = .normal
                    }
                } else if isLineTerminator(string.character(at: location)) {
                    advanceLineBreak()
                } else {
                    location += 1
                }

            case let .javascriptRegex(isInsideCharacterClass):
                let character = string.character(at: location)
                if isLineTerminator(character) {
                    emit(tokenStart ?? scanRange.location, location, .string)
                    tokenStart = nil
                    state = .normal
                } else if character == 0x5C {
                    location = min(end, location + 2)
                } else if character == 0x5B {
                    state = .javascriptRegex(true)
                    location += 1
                } else if character == 0x5D {
                    state = .javascriptRegex(false)
                    location += 1
                } else if character == 0x2F, !isInsideCharacterClass {
                    location += 1
                    while location < end,
                          isJavaScriptRegexFlag(string.character(at: location)) {
                        location += 1
                    }
                    emit(tokenStart ?? scanRange.location, location, .string)
                    tokenStart = nil
                    state = .normal
                } else {
                    location += 1
                }
            }
            checkpointIfNeeded()
        }

        if state == .lineComment || state == .blockComment {
            emit(tokenStart ?? scanRange.location, end, .comment)
        } else if case .string = state {
            emit(tokenStart ?? scanRange.location, end, .string)
        } else if case .javascriptRegex = state {
            emit(tokenStart ?? scanRange.location, end, .string)
        }
        return ScanResult(
            tokens: result,
            checkpoints: checkpoints,
            wasCancelled: false
        )
    }

    private static func hasPrefix(
        _ prefix: String,
        in string: NSString,
        at location: Int,
        limit: Int
    ) -> Bool {
        let prefixString = prefix as NSString
        let length = prefixString.length
        guard location >= 0, location + length <= limit else { return false }
        guard length > 0,
              string.character(at: location) == prefixString.character(at: 0) else {
            return false
        }
        if length == 1 { return true }
        for index in 1..<length where
            string.character(at: location + index) != prefixString.character(at: index) {
            return false
        }
        return true
    }

    private static func lineEnd(in string: NSString, from start: Int, limit: Int) -> Int {
        var location = start
        while location < limit, !isLineTerminator(string.character(at: location)) {
            location += 1
        }
        return location
    }

    private static func isLineTerminator(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D
            || character == 0x2028 || character == 0x2029
    }

    private static func isCommentBoundary(in string: NSString, at location: Int) -> Bool {
        guard location > 0 else { return true }
        let previous = string.character(at: location - 1)
        return isWhitespace(previous)
    }

    private static func isJavaScriptRegexStart(
        in string: NSString,
        at location: Int,
        lowerBound: Int
    ) -> Bool {
        var previous = location - 1
        while previous >= lowerBound,
              isWhitespace(string.character(at: previous)) {
            previous -= 1
        }
        guard previous >= lowerBound else { return true }
        let character = string.character(at: previous)
        switch character {
        case 0x28, 0x5B, 0x7B, 0x2C, 0x3B, 0x3A,
             0x3D, 0x21, 0x3F, 0x26, 0x7C, 0x2A,
             0x25, 0x7E, 0x5E, 0x3C, 0x3E:
            return true
        case 0x2B, 0x2D:
            return !(previous > lowerBound
                && string.character(at: previous - 1) == character)
        default:
            break
        }
        guard isJavaScriptIdentifierCharacter(character) else { return false }
        var wordStart = previous
        while wordStart > lowerBound,
              isJavaScriptIdentifierCharacter(string.character(at: wordStart - 1)) {
            wordStart -= 1
        }
        let word = string.substring(with: NSRange(
            location: wordStart,
            length: previous - wordStart + 1
        ))
        return javascriptRegexPrefixKeywords.contains(word)
    }

    private static func isWhitespace(_ codeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(codeUnit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
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
            if isLineTerminator(character) { return location }
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

    private static func isJavaScriptIdentifierCharacter(_ character: unichar) -> Bool {
        (character >= 0x41 && character <= 0x5A)
            || (character >= 0x61 && character <= 0x7A)
            || (character >= 0x30 && character <= 0x39)
            || character == 0x24 || character == 0x5F
    }

    private static func isJavaScriptRegexFlag(_ character: unichar) -> Bool {
        switch character {
        case 0x64, 0x67, 0x69, 0x6D, 0x73, 0x75, 0x76, 0x79: true
        default: false
        }
    }

    private static let javascriptRegexPrefixKeywords: Set<String> = [
        "case", "delete", "do", "else", "in", "instanceof", "new",
        "return", "throw", "typeof", "void", "yield", "await"
    ]
}
