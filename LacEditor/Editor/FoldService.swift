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
        let characters = Array(text.utf16)
        guard !characters.isEmpty else { return nil }
        var openingIndex: Int?
        var opening: UInt16 = 0
        var index = min(cursor, characters.count - 1)

        while index >= 0 {
            let value = characters[index]
            if value == 123 || value == 91 {
                openingIndex = index
                opening = value
                break
            }
            if index == 0 { break }
            index -= 1
        }
        guard let start = openingIndex else { return nil }
        let closing: UInt16 = opening == 123 ? 125 : 93
        var depth = 0
        var isInString = false
        var isEscaped = false

        for position in start..<characters.count {
            let value = characters[position]
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if value == 92 {
                    isEscaped = true
                } else if value == 34 {
                    isInString = false
                }
                continue
            }
            if value == 34 {
                isInString = true
            } else if value == opening {
                depth += 1
            } else if value == closing {
                depth -= 1
                if depth == 0, position > start + 1 {
                    return NSRange(location: start + 1, length: position - start - 1)
                }
            }
        }
        return nil
    }
}
