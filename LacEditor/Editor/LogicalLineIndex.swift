import Foundation

struct LineNumberLayoutTracker {
    private var lastDrawnY: CGFloat?

    mutating func shouldDraw(at y: CGFloat) -> Bool {
        guard let lastDrawnY else {
            self.lastDrawnY = y
            return true
        }
        guard abs(y - lastDrawnY) > 0.5 else { return false }
        self.lastDrawnY = y
        return true
    }
}

final class LogicalLineIndex {
    private(set) var textLength = 0
    private var lineStarts: [Int] = [0]

    init(text: String) {
        reset(with: text)
    }

    func reset(with text: String) {
        reset(with: text as NSString)
    }

    func reset(with value: NSString) {
        textLength = value.length
        lineStarts = [0]
        guard value.length > 0 else { return }
        var location = 0
        while location < value.length {
            let character = value.character(at: location)
            if character == 0x0D,
               location + 1 < value.length,
               value.character(at: location + 1) == 0x0A {
                lineStarts.append(location + 2)
                location += 2
                continue
            }
            if Self.isLineSeparator(character) {
                lineStarts.append(location + 1)
            }
            location += 1
        }
    }

    func applyEdit(
        range: NSRange,
        replacement: String,
        in originalText: NSString? = nil
    ) {
        let safeLocation = min(max(0, range.location), textLength)
        let safeLength = min(max(0, range.length), textLength - safeLocation)
        let safeEnd = safeLocation + safeLength
        let replacementValue = replacement as NSString

        if let originalText,
           requiresFullRescan(
               originalText: originalText,
               range: NSRange(location: safeLocation, length: safeLength),
               replacement: replacementValue
           ) {
            let updated = NSMutableString(string: originalText)
            updated.replaceCharacters(
                in: NSRange(location: safeLocation, length: safeLength),
                with: replacement
            )
            reset(with: updated as String)
            return
        }

        let delta = replacementValue.length - safeLength

        let retained = lineStarts.filter { $0 <= safeLocation }
        let shifted = lineStarts
            .filter { $0 > safeEnd }
            .map { $0 + delta }
        var inserted: [Int] = []
        if replacementValue.length > 0 {
            var location = 0
            while location < replacementValue.length {
                let character = replacementValue.character(at: location)
                if character == 0x0D,
                   location + 1 < replacementValue.length,
                   replacementValue.character(at: location + 1) == 0x0A {
                    inserted.append(safeLocation + location + 2)
                    location += 2
                    continue
                }
                if Self.isLineSeparator(character) {
                    inserted.append(safeLocation + location + 1)
                }
                location += 1
            }
        }

        lineStarts = retained + inserted + shifted
        if lineStarts.first != 0 {
            lineStarts.insert(0, at: 0)
        }
        textLength += delta
    }

    private func requiresFullRescan(
        originalText: NSString,
        range: NSRange,
        replacement: NSString
    ) -> Bool {
        let contextStart = max(0, range.location - 1)
        let contextEnd = min(originalText.length, NSMaxRange(range) + 1)
        if contextEnd > contextStart {
            for location in contextStart..<contextEnd {
                let character = originalText.character(at: location)
                if character == 0x0D || character == 0x2028 || character == 0x2029 {
                    return true
                }
            }
        }
        if replacement.length > 0 {
            for location in 0..<replacement.length {
                let character = replacement.character(at: location)
                if character == 0x0D || character == 0x2028 || character == 0x2029 {
                    return true
                }
            }
        }
        return false
    }

    private static func isLineSeparator(_ character: unichar) -> Bool {
        character == 0x0A
            || character == 0x0D
            || character == 0x2028
            || character == 0x2029
    }

    func lineNumber(at location: Int) -> Int {
        upperBound(for: min(max(0, location), textLength))
    }

    func position(
        at location: Int,
        in text: NSString
    ) -> (line: Int, column: Int) {
        let safeLocation = min(max(0, location), text.length)
        let line = upperBound(for: safeLocation)
        let lineStart = lineStarts[max(0, line - 1)]
        let columnText = text.substring(with: NSRange(
            location: lineStart,
            length: max(0, safeLocation - lineStart)
        ))
        return (line, columnText.count + 1)
    }

    private func upperBound(for location: Int) -> Int {
        var lower = 0
        var upper = lineStarts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lineStarts[middle] <= location {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return max(1, lower)
    }
}

extension LogicalLineIndex {
    static func selectedLineLocations(
        in text: NSString,
        selectedRange: NSRange
    ) -> ClosedRange<Int> {
        let selectionLocation = min(max(0, selectedRange.location), text.length)
        let selectionLength = min(
            max(0, selectedRange.length),
            text.length - selectionLocation
        )

        let firstLineLocation: Int
        if selectionLocation == text.length,
           text.length == 0 || isLineSeparator(text.character(at: text.length - 1)) {
            firstLineLocation = text.length
        } else {
            let firstAnchor = min(selectionLocation, max(0, text.length - 1))
            firstLineLocation = text.lineRange(
                for: NSRange(location: firstAnchor, length: 0)
            ).location
        }

        guard selectionLength > 0 else {
            return firstLineLocation...firstLineLocation
        }
        let lastAnchor = selectionLocation + selectionLength - 1
        let lastLineLocation = text.lineRange(
            for: NSRange(location: lastAnchor, length: 0)
        ).location
        return min(firstLineLocation, lastLineLocation)...max(
            firstLineLocation,
            lastLineLocation
        )
    }

    static func layoutAnchorCharacterIndex(
        in text: NSString,
        lineRange: NSRange,
        foldedRange: NSRange? = nil
    ) -> Int {
        var contentEnd = NSMaxRange(lineRange)
        while contentEnd > lineRange.location {
            let value = text.character(at: contentEnd - 1)
            guard value == 0x0A
                    || value == 0x0D
                    || value == 0x2028
                    || value == 0x2029 else {
                break
            }
            contentEnd -= 1
        }
        guard contentEnd > lineRange.location else { return lineRange.location }
        if let foldedRange,
           NSLocationInRange(lineRange.location, foldedRange) {
            return min(NSMaxRange(foldedRange), contentEnd - 1)
        }
        return lineRange.location
    }
}
