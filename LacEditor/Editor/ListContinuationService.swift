import Foundation

enum ListContinuationService {
    private static let continuationOrderedExpression = try! NSRegularExpression(
        pattern: #"^(\d+)([.)])\s+(.+)$"#
    )
    private static let continuationUnorderedExpression = try! NSRegularExpression(
        pattern: #"^([-*+])\s+(.+)$"#
    )
    private static let orderedItemExpression = try! NSRegularExpression(
        pattern: #"^([ \t]*)(\d+)([.)])\s+.*$"#
    )
    private static let emptyItemExpression = try! NSRegularExpression(
        pattern: #"^(?:\d+[.)]|[-*+])\s*$"#
    )
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
            expression: continuationOrderedExpression,
            in: String(content)
        ), let number = Int(ordered[1]) {
            return "\(number + 1)\(ordered[2]) "
        }

        if let unordered = firstMatch(
            expression: continuationUnorderedExpression,
            in: String(content)
        ) {
            return "\(unordered[1]) "
        }

        return nil
    }

    static func isEmptyListItem(_ linePrefix: String) -> Bool {
        let content = linePrefix.drop { $0 == " " || $0 == "\t" }
        let value = String(content)
        return emptyItemExpression.firstMatch(
            in: value,
            range: NSRange(location: 0, length: (value as NSString).length)
        ) != nil
    }

    static func isManualOrderedMarkerEdit(
        in text: String,
        range: NSRange,
        replacement: String
    ) -> Bool {
        isManualOrderedMarkerEdit(
            in: text as NSString,
            range: range,
            replacement: replacement
        )
    }

    static func isManualOrderedMarkerEdit(
        in nsText: NSString,
        range: NSRange,
        replacement: String
    ) -> Bool {
        guard !replacement.contains("\n") else { return false }
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
        shouldNormalizeOrderedListEdit(
            in: text as NSString,
            range: range,
            replacement: replacement
        )
    }

    static func shouldNormalizeOrderedListEdit(
        in nsText: NSString,
        range: NSRange,
        replacement: String
    ) -> Bool {
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
        let nsText = text as NSString
        guard nsText.length > 0 else { return nil }
        let boundedLocation = min(max(location, 0), nsText.length)
        let anchorLocation = min(boundedLocation, max(0, nsText.length - 1))
        let anchorRange = nsText.lineRange(
            for: NSRange(location: anchorLocation, length: 0)
        )
        let nearbyRanges = [
            anchorRange,
            nextLineRange(after: anchorRange, in: nsText),
            previousLineRange(before: anchorRange, in: nsText)
        ].compactMap { $0 }
        guard let candidate = nearbyRanges.compactMap({ range in
            orderedItem(in: nsText, lineRange: range)
        }).first else { return nil }

        var before: [OrderedItem] = []
        var range = previousLineRange(
            before: nsText.lineRange(for: NSRange(
                location: candidate.numberRange.location,
                length: 0
            )),
            in: nsText
        )
        while let currentRange = range {
            let scan = scanLine(
                currentRange,
                in: nsText,
                matching: candidate
            )
            if let item = scan.item { before.append(item) }
            if scan.stopsSequence { break }
            range = previousLineRange(before: currentRange, in: nsText)
        }

        var after: [OrderedItem] = []
        range = nextLineRange(
            after: nsText.lineRange(for: NSRange(
                location: candidate.numberRange.location,
                length: 0
            )),
            in: nsText
        )
        while let currentRange = range {
            let scan = scanLine(
                currentRange,
                in: nsText,
                matching: candidate
            )
            if let item = scan.item { after.append(item) }
            if scan.stopsSequence { break }
            range = nextLineRange(after: currentRange, in: nsText)
        }

        let sequence = Array(before.reversed()) + [candidate] + after
        guard sequence.count > 1 else { return nil }
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

    static func orderedListExceedsBackgroundThreshold(
        in text: NSString,
        aroundUTF16Location location: Int,
        threshold: Int = 500
    ) -> Bool {
        guard text.length > 0, threshold > 0 else { return false }
        let anchor = min(max(location, 0), text.length - 1)
        let anchorRange = text.lineRange(for: NSRange(location: anchor, length: 0))
        let nearbyRanges = [
            anchorRange,
            nextLineRange(after: anchorRange, in: text),
            previousLineRange(before: anchorRange, in: text)
        ].compactMap { $0 }
        guard let candidate = nearbyRanges.compactMap({ range in
            orderedItem(in: text, lineRange: range)
        }).first else { return false }

        var count = 1
        var range = previousLineRange(
            before: text.lineRange(for: NSRange(
                location: candidate.numberRange.location,
                length: 0
            )),
            in: text
        )
        while let currentRange = range {
            let scan = scanLine(currentRange, in: text, matching: candidate)
            if scan.item != nil {
                count += 1
                if count > threshold { return true }
            }
            if scan.stopsSequence { break }
            range = previousLineRange(before: currentRange, in: text)
        }
        range = nextLineRange(
            after: text.lineRange(for: NSRange(
                location: candidate.numberRange.location,
                length: 0
            )),
            in: text
        )
        while let currentRange = range {
            let scan = scanLine(currentRange, in: text, matching: candidate)
            if scan.item != nil {
                count += 1
                if count > threshold { return true }
            }
            if scan.stopsSequence { break }
            range = nextLineRange(after: currentRange, in: text)
        }
        return false
    }

    private static func orderedItem(
        in text: NSString,
        lineRange: NSRange
    ) -> OrderedItem? {
        let contentRange = text.lineRange(for: lineRange)
        let line = text.substring(with: contentRange)
            .trimmingCharacters(in: .newlines)
        return orderedItem(in: line, lineStart: contentRange.location)
    }

    private static func scanLine(
        _ lineRange: NSRange,
        in text: NSString,
        matching candidate: OrderedItem
    ) -> (item: OrderedItem?, stopsSequence: Bool) {
        let rawLine = text.substring(with: lineRange)
            .trimmingCharacters(in: .newlines)
        if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
            return (nil, false)
        }
        if let item = orderedItem(in: rawLine, lineStart: lineRange.location) {
            if item.indentWidth == candidate.indentWidth,
               item.delimiter == candidate.delimiter {
                return (item, false)
            }
            return (nil, item.indentWidth <= candidate.indentWidth)
        }
        let indentation = rawLine.prefix { $0 == " " || $0 == "\t" }
        let width = indentation.reduce(into: 0) { total, character in
            total += character == "\t" ? 4 : 1
        }
        return (nil, width <= candidate.indentWidth)
    }

    private static func previousLineRange(
        before lineRange: NSRange,
        in text: NSString
    ) -> NSRange? {
        guard lineRange.location > 0 else { return nil }
        return text.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
    }

    private static func nextLineRange(
        after lineRange: NSRange,
        in text: NSString
    ) -> NSRange? {
        let nextLocation = NSMaxRange(lineRange)
        guard nextLocation < text.length else { return nil }
        return text.lineRange(for: NSRange(location: nextLocation, length: 0))
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
            expression: orderedItemExpression,
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

    private static func boundedRange(
        _ range: NSRange,
        textLength: Int
    ) -> NSRange {
        let location = min(range.location, textLength)
        let length = min(range.length, textLength - location)
        return NSRange(location: location, length: length)
    }

    private static func firstMatch(
        expression: NSRegularExpression,
        in value: String
    ) -> [String]? {
        guard let match = expression.firstMatch(
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
