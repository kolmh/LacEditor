import Combine
import Foundation

enum FindReplaceMode: String, CaseIterable, Identifiable {
    case find = "查找"
    case replace = "替换"

    var id: String { rawValue }
}

@MainActor
final class FindReplaceState: ObservableObject {
    @Published var mode: FindReplaceMode = .find
    @Published var query = ""
    @Published var replacement = ""
    @Published var interpretsEscapes = true
    @Published var isCaseSensitive = false
    @Published var message: String?
    @Published var isWorking = false
    @Published var activeDocumentID: UUID?
    @Published var focusRequestID = UUID()
}

enum TextSearchService {
    static func interpreted(_ value: String, enabled: Bool) -> String {
        guard enabled else { return value }
        var result = ""
        var isEscaping = false

        for character in value {
            if isEscaping {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "s": result.append(" ")
                case "0": result.append("\0")
                case "\\": result.append("\\")
                default:
                    result.append("\\")
                    result.append(character)
                }
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else {
                result.append(character)
            }
        }
        if isEscaping { result.append("\\") }
        return result
    }

    static func nextRange(
        in text: String,
        query: String,
        after selection: NSRange,
        caseSensitive: Bool
    ) -> NSRange? {
        let nsText = text as NSString
        guard !query.isEmpty, nsText.length > 0 else { return nil }
        let options = compareOptions(caseSensitive: caseSensitive)
        let start = min(NSMaxRange(selection), nsText.length)
        let tail = NSRange(location: start, length: nsText.length - start)
        let match = nsText.range(of: query, options: options, range: tail)
        if match.location != NSNotFound { return match }
        let wrapped = nsText.range(
            of: query,
            options: options,
            range: NSRange(location: 0, length: start)
        )
        return wrapped.location == NSNotFound ? nil : wrapped
    }

    static func previousRange(
        in text: String,
        query: String,
        before selection: NSRange,
        caseSensitive: Bool
    ) -> NSRange? {
        let nsText = text as NSString
        guard !query.isEmpty, nsText.length > 0 else { return nil }
        var options = compareOptions(caseSensitive: caseSensitive)
        options.insert(.backwards)
        let end = min(selection.location, nsText.length)
        let head = NSRange(location: 0, length: end)
        let match = nsText.range(of: query, options: options, range: head)
        if match.location != NSNotFound { return match }
        let wrapped = nsText.range(
            of: query,
            options: options,
            range: NSRange(location: end, length: nsText.length - end)
        )
        return wrapped.location == NSNotFound ? nil : wrapped
    }

    static func selectionMatches(
        in text: String,
        query: String,
        selection: NSRange,
        caseSensitive: Bool
    ) -> Bool {
        let nsText = text as NSString
        guard selection.location != NSNotFound,
              NSMaxRange(selection) <= nsText.length,
              selection.length == (query as NSString).length else { return false }
        let selected = nsText.substring(with: selection)
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        return selected.compare(query, options: options) == .orderedSame
    }

    static func replacingAll(
        in text: String,
        query: String,
        replacement: String,
        caseSensitive: Bool,
        isCancelled: () -> Bool = { false }
    ) -> (text: String, count: Int) {
        guard !query.isEmpty else { return (text, 0) }
        let nsText = text as NSString
        let options = compareOptions(caseSensitive: caseSensitive)
        var count = 0
        var location = 0

        while location <= nsText.length {
            if count.isMultiple(of: 512), isCancelled() { return (text, 0) }
            let range = NSRange(location: location, length: nsText.length - location)
            let match = nsText.range(of: query, options: options, range: range)
            guard match.location != NSNotFound else { break }
            count += 1
            location = NSMaxRange(match)
        }

        let output = nsText.replacingOccurrences(
            of: query,
            with: replacement,
            options: options,
            range: NSRange(location: 0, length: nsText.length)
        )
        return (output, count)
    }

    private static func compareOptions(caseSensitive: Bool) -> NSString.CompareOptions {
        caseSensitive ? [.literal] : [.literal, .caseInsensitive]
    }
}
