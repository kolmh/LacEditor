import Foundation

final class LogicalLineIndex {
    private(set) var textLength = 0
    private var lineStarts: [Int] = [0]

    init(text: String) {
        reset(with: text)
    }

    func reset(with text: String) {
        let value = text as NSString
        textLength = value.length
        lineStarts = [0]
        guard value.length > 0 else { return }
        for location in 0..<value.length
        where value.character(at: location) == 0x0A {
            lineStarts.append(location + 1)
        }
    }

    func applyEdit(range: NSRange, replacement: String) {
        let safeLocation = min(max(0, range.location), textLength)
        let safeLength = min(max(0, range.length), textLength - safeLocation)
        let safeEnd = safeLocation + safeLength
        let replacementValue = replacement as NSString
        let delta = replacementValue.length - safeLength

        let retained = lineStarts.filter { $0 <= safeLocation }
        let shifted = lineStarts
            .filter { $0 > safeEnd }
            .map { $0 + delta }
        var inserted: [Int] = []
        if replacementValue.length > 0 {
            for location in 0..<replacementValue.length
            where replacementValue.character(at: location) == 0x0A {
                inserted.append(safeLocation + location + 1)
            }
        }

        lineStarts = retained + inserted + shifted
        if lineStarts.first != 0 {
            lineStarts.insert(0, at: 0)
        }
        textLength += delta
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
