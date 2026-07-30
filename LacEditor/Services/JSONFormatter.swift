import Foundation

enum JSONFormatter {
    static func format(_ text: String, pretty: Bool) throws -> String {
        let data = Data(text.utf8)
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let options: JSONSerialization.WritingOptions = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        let output = try JSONSerialization.data(withJSONObject: object, options: options)
        return String(decoding: output, as: UTF8.self) + (pretty ? "\n" : "")
    }

    static func userFacingError(_ error: Error, in text: String) -> String {
        let nsError = error as NSError
        let description = nsError.localizedDescription
        if let location = lineAndColumn(from: description) {
            return "JSON 无效：第 \(location.line) 行，第 \(location.column) 列。\(description)"
        }
        if let index = byteIndex(from: description) {
            let prefix = text.utf8.prefix(index)
            let decodedPrefix = String(decoding: prefix, as: UTF8.self)
            let line = decodedPrefix.reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            }
            let column = decodedPrefix.split(separator: "\n", omittingEmptySubsequences: false).last?.count ?? 0
            return "JSON 无效：第 \(line) 行，第 \(column + 1) 列。\(description)"
        }
        return "JSON 无效：\(description)"
    }

    private static func lineAndColumn(from description: String) -> (line: Int, column: Int)? {
        let pattern = #"line\s+(\d+)[,\s]+column\s+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(
                in: description,
                range: NSRange(description.startIndex..., in: description)
              ),
              let lineRange = Range(match.range(at: 1), in: description),
              let columnRange = Range(match.range(at: 2), in: description),
              let line = Int(description[lineRange]),
              let column = Int(description[columnRange]) else { return nil }
        return (line, column)
    }

    private static func byteIndex(from description: String) -> Int? {
        let patterns = [
            #"around character (\d+)"#,
            #"at line \d+ column \d+.*character (\d+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: description,
                    range: NSRange(description.startIndex..., in: description)
                  ),
                  let range = Range(match.range(at: 1), in: description) else { continue }
            return Int(description[range])
        }
        return nil
    }
}
