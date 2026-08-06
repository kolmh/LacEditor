import Foundation

enum FoldService {
    static func foldableRange(in text: String, at cursor: Int, language: EditorLanguage) -> NSRange? {
        switch language {
        case .markdown:
            markdownRange(in: text, at: cursor)
        case .json:
            jsonRange(in: text, at: cursor)
        default:
            nil
        }
    }

    private static func markdownRange(in text: String, at cursor: Int) -> NSRange? {
        let nsText = text as NSString
        guard cursor <= nsText.length else { return nil }
        let currentLine = nsText.lineRange(for: NSRange(location: cursor, length: 0))
        let line = nsText.substring(with: currentLine)
        guard let match = line.range(of: #"^(#{1,6})\s+"#, options: .regularExpression) else { return nil }
        let level = line[match].prefix { $0 == "#" }.count
        var end = NSMaxRange(currentLine)

        while end < nsText.length {
            let candidateRange = nsText.lineRange(for: NSRange(location: end, length: 0))
            let candidate = nsText.substring(with: candidateRange)
            if let heading = candidate.range(of: #"^(#{1,6})\s+"#, options: .regularExpression) {
                let candidateLevel = candidate[heading].prefix { $0 == "#" }.count
                if candidateLevel <= level { break }
            }
            end = NSMaxRange(candidateRange)
        }
        let bodyStart = NSMaxRange(currentLine)
        guard end > bodyStart else { return nil }
        return NSRange(location: bodyStart, length: end - bodyStart)
    }

    private static func jsonRange(in text: String, at cursor: Int) -> NSRange? {
        let characters = text as NSString
        guard characters.length > 0 else { return nil }
        let safeCursor = min(max(cursor, 0), characters.length - 1)
        var stack: [(index: Int, delimiter: UInt16)] = []
        var isInString = false
        var isEscaped = false

        func consume(at position: Int) {
            let value = characters.character(at: position)
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if value == 92 {
                    isEscaped = true
                } else if value == 34 {
                    isInString = false
                }
            } else if value == 34 {
                isInString = true
            } else if value == 123 || value == 91 {
                stack.append((position, value))
            } else if value == 125 || value == 93,
                      let last = stack.last {
                let matches = (last.delimiter == 123 && value == 125)
                    || (last.delimiter == 91 && value == 93)
                if matches {
                    stack.removeLast()
                }
            }
        }

        if safeCursor > 0 {
            for position in 0..<safeCursor {
                consume(at: position)
            }
        }
        let cursorCharacter = characters.character(at: safeCursor)
        if cursorCharacter == 123 || cursorCharacter == 91 {
            consume(at: safeCursor)
        }

        guard let container = stack.last else { return nil }
        let start = container.index
        var scanStack: [UInt16] = []
        isInString = false
        isEscaped = false
        for position in start..<characters.length {
            let value = characters.character(at: position)
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if value == 92 {
                    isEscaped = true
                } else if value == 34 {
                    isInString = false
                }
            } else if value == 34 {
                isInString = true
            } else if value == 123 || value == 91 {
                scanStack.append(value)
            } else if value == 125 || value == 93,
                      let opening = scanStack.last {
                let matches = (opening == 123 && value == 125)
                    || (opening == 91 && value == 93)
                guard matches else { return nil }
                scanStack.removeLast()
                if scanStack.isEmpty, position > start + 1 {
                    return NSRange(
                        location: start + 1,
                        length: position - start - 1
                    )
                }
            }
        }
        return nil
    }
}
