import Foundation

enum ListContinuationService {
    struct OrderedListEdit {
        let range: NSRange
        let replacement: String
    }

    struct OrderedListNormalization {
        let text: String
        let edits: [OrderedListEdit]

        func mappedLocation(for location: Int) -> Int {
            edits.reduce(location) { mappedLocation, edit in
                guard edit.range.location < location else { return mappedLocation }
                if NSMaxRange(edit.range) <= location {
                    return mappedLocation
                        + (edit.replacement as NSString).length
                        - edit.range.length
                }
                return edit.range.location + (edit.replacement as NSString).length
            }
        }
    }

    static func continuation(for linePrefix: String) -> String? {
        let content = linePrefix.drop { $0 == " " || $0 == "\t" }

        if let ordered = firstMatch(
            pattern: #"^(\d+)([.)])\s+(.+)$"#,
            in: String(content)
        ), let number = Int(ordered[1]) {
            return "\(number + 1)\(ordered[2]) "
        }

        if let unordered = firstMatch(
            pattern: #"^([-*+])\s+(.+)$"#,
            in: String(content)
        ) {
            return "\(unordered[1]) "
        }

        return nil
    }

    static func isEmptyListItem(_ linePrefix: String) -> Bool {
        let content = linePrefix.drop { $0 == " " || $0 == "\t" }
        return String(content).range(
            of: #"^(?:\d+[.)]|[-*+])\s*$"#,
            options: .regularExpression
        ) != nil
    }

    static func isManualOrderedMarkerEdit(
        in text: String,
        range: NSRange,
        replacement: String
    ) -> Bool {
        guard !replacement.contains("\n") else { return false }
        let nsText = text as NSString
        let safeRange = boundedRange(range, textLength: nsText.length)
        guard !nsText.substring(with: safeRange).contains("\n") else {
            return false
        }
        let safeLocation = min(range.location, nsText.length)
        let lineRange = nsText.lineRange(for: NSRange(location: safeLocation, length: 0))
        let line = nsText.substring(with: lineRange)
            .trimmingCharacters(in: .newlines)
        guard let item = orderedItem(in: line, lineStart: lineRange.location) else {
            return false
        }

        let numberRange = item.numberRange
        if range.length == 0 {
            return range.location >= numberRange.location
                && range.location <= NSMaxRange(numberRange)
        }
        return NSIntersectionRange(range, numberRange).length > 0
    }

    static func shouldNormalizeOrderedListEdit(
        in text: String,
        range: NSRange,
        replacement: String
    ) -> Bool {
        let nsText = text as NSString
        let safeRange = boundedRange(range, textLength: nsText.length)
        let removedText = nsText.substring(with: safeRange)
        guard replacement.contains("\n") || removedText.contains("\n") else {
            return false
        }

        // A multi-line paste carries explicit numbering chosen by the user.
        // Preserve it instead of treating it as a single inserted list item.
        if replacement.contains("\n"), !replacement.hasPrefix("\n") {
            return false
        }

        // LacTextView already creates the correct next marker on Return. At the
        // end of the document there are no following items that need reflowing.
        if safeRange.length == 0,
           safeRange.location == nsText.length,
           replacement.hasPrefix("\n") {
            return false
        }

        return true
    }

    static func normalizeOrderedList(
        in text: String,
        aroundUTF16Location location: Int
    ) -> OrderedListNormalization? {
        let lines = text.components(separatedBy: "\n")
        var lineStarts: [Int] = []
        var offset = 0
        for (index, line) in lines.enumerated() {
            lineStarts.append(offset)
            offset += (line as NSString).length
            if index + 1 < lines.count {
                offset += 1
            }
        }

        let boundedLocation = min(max(location, 0), (text as NSString).length)
        let currentLine = max(
            0,
            min(
                lineStarts.lastIndex(where: { $0 <= boundedLocation }) ?? 0,
                lines.count - 1
            )
        )
        let items = lines.enumerated().compactMap { index, line in
            orderedItem(in: line, lineStart: lineStarts[index], lineIndex: index)
        }
        guard !items.isEmpty else { return nil }

        let candidate = items.first(where: { $0.lineIndex == currentLine })
            ?? items.first(where: { $0.lineIndex == currentLine + 1 })
            ?? items.last(where: { $0.lineIndex < currentLine })
        guard let candidate else { return nil }

        let candidateIndex = items.firstIndex(where: {
            $0.lineIndex == candidate.lineIndex
                && $0.numberRange.location == candidate.numberRange.location
        }) ?? 0

        var firstItemIndex = candidateIndex
        while firstItemIndex > 0 {
            let previous = items[firstItemIndex - 1]
            let current = items[firstItemIndex]
            guard belongsToSameSequence(
                previous,
                current,
                lines: lines
            ) else { break }
            firstItemIndex -= 1
        }

        var lastItemIndex = candidateIndex
        while lastItemIndex + 1 < items.count {
            let current = items[lastItemIndex]
            let next = items[lastItemIndex + 1]
            guard belongsToSameSequence(
                current,
                next,
                lines: lines
            ) else { break }
            lastItemIndex += 1
        }

        guard lastItemIndex > firstItemIndex else { return nil }
        let sequence = Array(items[firstItemIndex...lastItemIndex])
        let startingNumber = sequence[0].number
        let edits = sequence.enumerated().compactMap { index, item -> OrderedListEdit? in
            let expectedNumber = startingNumber + index
            guard item.number != expectedNumber else { return nil }
            return OrderedListEdit(
                range: item.numberRange,
                replacement: String(expectedNumber)
            )
        }
        guard !edits.isEmpty else { return nil }

        let mutableText = NSMutableString(string: text)
        for edit in edits.reversed() {
            mutableText.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return OrderedListNormalization(text: mutableText as String, edits: edits)
    }

    private struct OrderedItem {
        let lineIndex: Int
        let indentWidth: Int
        let number: Int
        let delimiter: String
        let numberRange: NSRange
    }

    private static func orderedItem(
        in line: String,
        lineStart: Int,
        lineIndex: Int = 0
    ) -> OrderedItem? {
        guard let match = firstMatch(
            pattern: #"^([ \t]*)(\d+)([.)])\s+.*$"#,
            in: line
        ), let number = Int(match[2]) else {
            return nil
        }

        let nsLine = line as NSString
        let searchStart = (match[1] as NSString).length
        let numberRangeInLine = nsLine.range(
            of: match[2],
            options: [],
            range: NSRange(location: searchStart, length: nsLine.length - searchStart)
        )
        guard numberRangeInLine.location != NSNotFound else { return nil }

        let indentWidth = match[1].reduce(into: 0) { width, character in
            width += character == "\t" ? 4 : 1
        }
        return OrderedItem(
            lineIndex: lineIndex,
            indentWidth: indentWidth,
            number: number,
            delimiter: match[3],
            numberRange: NSRange(
                location: lineStart + numberRangeInLine.location,
                length: numberRangeInLine.length
            )
        )
    }

    private static func belongsToSameSequence(
        _ first: OrderedItem,
        _ second: OrderedItem,
        lines: [String]
    ) -> Bool {
        guard first.indentWidth == second.indentWidth,
              first.delimiter == second.delimiter,
              first.lineIndex < second.lineIndex else {
            return false
        }

        guard second.lineIndex - first.lineIndex > 1 else { return true }
        return lines[(first.lineIndex + 1)..<second.lineIndex].allSatisfy { line in
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            let indentation = line.prefix { $0 == " " || $0 == "\t" }
            let width = indentation.reduce(into: 0) { total, character in
                total += character == "\t" ? 4 : 1
            }
            return width > first.indentWidth
        }
    }

    private static func boundedRange(
        _ range: NSRange,
        textLength: Int
    ) -> NSRange {
        let location = min(range.location, textLength)
        let length = min(range.length, textLength - location)
        return NSRange(location: location, length: length)
    }

    private static func firstMatch(pattern: String, in value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: value,
                range: NSRange(location: 0, length: (value as NSString).length)
              ) else { return nil }

        let nsValue = value as NSString
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : nsValue.substring(with: range)
        }
    }
}
