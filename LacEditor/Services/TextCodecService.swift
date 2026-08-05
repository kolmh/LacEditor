import Foundation

enum TextCodecKind: String, Sendable {
    case url = "URL 编码"
    case base64 = "Base64"
    case base64URL = "Base64URL"
    case htmlEntity = "HTML 实体"
    case unicodeEscape = "Unicode/JSON 转义"
}

enum TextTransformationOperation: String, CaseIterable, Sendable {
    case smartDecode
    case urlEncodeComponent
    case urlDecode
    case formURLDecode
    case base64Encode
    case base64Decode
    case base64URLEncode
    case base64URLDecode
    case htmlEncode
    case htmlDecode
    case unicodeEncode
    case unicodeDecode

    var title: String {
        switch self {
        case .smartDecode: "智能解码"
        case .urlEncodeComponent: "URL 组件编码"
        case .urlDecode: "URL 解码"
        case .formURLDecode: "表单 URL 解码"
        case .base64Encode: "Base64 编码"
        case .base64Decode: "Base64 解码"
        case .base64URLEncode: "Base64URL 编码"
        case .base64URLDecode: "Base64URL 解码"
        case .htmlEncode: "HTML 实体编码"
        case .htmlDecode: "HTML 实体解码"
        case .unicodeEncode: "Unicode/JSON 转义"
        case .unicodeDecode: "Unicode/JSON 反转义"
        }
    }

    var actionName: String { title }
}

struct TextCodecDetection: Sendable, Equatable {
    let kind: TextCodecKind
    let operation: TextTransformationOperation
    let output: String

    var suggestionTitle: String { "检测到 \(kind.rawValue)" }
}

enum TextCodecError: LocalizedError, Equatable {
    case emptyInput
    case invalidPercentEncoding
    case invalidBase64
    case nonTextBase64
    case invalidHTMLEntity(String)
    case invalidUnicodeEscape(String)
    case noDetectedEncoding

    var errorDescription: String? {
        switch self {
        case .emptyInput: "没有可转换的文本"
        case .invalidPercentEncoding: "URL 编码无效，请检查百分号后的十六进制字符"
        case .invalidBase64: "Base64 内容或填充格式无效"
        case .nonTextBase64: "Base64 解码结果不是 UTF-8 文本"
        case let .invalidHTMLEntity(entity): "HTML 实体无效：\(entity)"
        case let .invalidUnicodeEscape(escape): "Unicode/JSON 转义无效：\(escape)"
        case .noDetectedEncoding: "没有检测到可解码的内容"
        }
    }
}

enum TextCodecService {
    static let automaticDetectionLimit = 16 * 1_024

    static func transform(
        _ input: String,
        operation: TextTransformationOperation
    ) throws -> String {
        guard !input.isEmpty else { throw TextCodecError.emptyInput }
        switch operation {
        case .smartDecode:
            guard let detection = detect(in: input) else {
                throw TextCodecError.noDetectedEncoding
            }
            return detection.output
        case .urlEncodeComponent:
            return percentEncode(input)
        case .urlDecode:
            return try percentDecode(input, treatsPlusAsSpace: false)
        case .formURLDecode:
            return try percentDecode(input, treatsPlusAsSpace: true)
        case .base64Encode:
            return Data(input.utf8).base64EncodedString()
        case .base64Decode:
            return try base64Decode(input, urlSafe: false)
        case .base64URLEncode:
            return Data(input.utf8)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        case .base64URLDecode:
            return try base64Decode(input, urlSafe: true)
        case .htmlEncode:
            return htmlEncode(input)
        case .htmlDecode:
            return try htmlDecode(input)
        case .unicodeEncode:
            return unicodeEscape(input)
        case .unicodeDecode:
            return try unicodeUnescape(input)
        }
    }

    static func detect(
        in input: String,
        allowsBase64: Bool = true
    ) -> TextCodecDetection? {
        guard !input.isEmpty,
              input.utf16.count <= automaticDetectionLimit else { return nil }

        if input.contains("%"),
           let output = try? transform(input, operation: .urlDecode),
           output != input {
            return TextCodecDetection(
                kind: .url,
                operation: .urlDecode,
                output: output
            )
        }

        if containsUnicodeEscape(input),
           let output = try? transform(input, operation: .unicodeDecode),
           output != input {
            return TextCodecDetection(
                kind: .unicodeEscape,
                operation: .unicodeDecode,
                output: output
            )
        }

        if input.contains("&"), input.contains(";"),
           let output = try? transform(input, operation: .htmlDecode),
           output != input {
            return TextCodecDetection(
                kind: .htmlEntity,
                operation: .htmlDecode,
                output: output
            )
        }

        if allowsBase64, let detection = base64Detection(input) { return detection }
        return nil
    }

    static func candidate(
        in text: NSString,
        selection: NSRange,
        allowsTokenAtCaret: Bool,
        maximumLength: Int? = nil
    ) -> (range: NSRange, text: String)? {
        let documentRange = NSRange(location: 0, length: text.length)
        guard selection.location != NSNotFound,
              selection.location <= text.length else { return nil }

        if selection.length > 0 {
            guard NSMaxRange(selection) <= text.length,
                  maximumLength.map({ selection.length <= $0 }) ?? true else { return nil }
            return (selection, text.substring(with: selection))
        }

        guard allowsTokenAtCaret, text.length > 0 else { return nil }
        let limit = maximumLength ?? Int.max
        var start = min(selection.location, text.length)
        var end = start
        while start > 0, end - start < limit,
              !isWhitespace(text.character(at: start - 1)) {
            start -= 1
        }
        while end < text.length, end - start < limit,
              !isWhitespace(text.character(at: end)) {
            end += 1
        }

        if end - start == limit {
            let continuesBefore = start > 0
                && !isWhitespace(text.character(at: start - 1))
            let continuesAfter = end < text.length
                && !isWhitespace(text.character(at: end))
            guard !continuesBefore, !continuesAfter else { return nil }
        }

        var range = NSIntersectionRange(
            NSRange(location: start, length: max(0, end - start)),
            documentRange
        )
        trimTokenPunctuation(in: text, range: &range)
        guard range.length > 0,
              maximumLength.map({ range.length <= $0 }) ?? true else { return nil }
        return (range, text.substring(with: range))
    }

    private static func percentEncode(_ input: String) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        return input.utf8.map { byte in
            unreserved.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }

    private static func percentDecode(
        _ input: String,
        treatsPlusAsSpace: Bool
    ) throws -> String {
        var index = input.startIndex
        var containsEscape = false
        while index < input.endIndex {
            if input[index] == "%" {
                containsEscape = true
                guard let first = input.index(index, offsetBy: 1, limitedBy: input.endIndex),
                      let second = input.index(index, offsetBy: 2, limitedBy: input.endIndex),
                      first < input.endIndex,
                      second < input.endIndex,
                      input[first].isHexDigit,
                      input[second].isHexDigit else {
                    throw TextCodecError.invalidPercentEncoding
                }
                index = input.index(after: second)
            } else {
                index = input.index(after: index)
            }
        }
        guard containsEscape || (treatsPlusAsSpace && input.contains("+")) else {
            throw TextCodecError.invalidPercentEncoding
        }
        let source = treatsPlusAsSpace
            ? input.replacingOccurrences(of: "+", with: " ")
            : input
        guard let decoded = source.removingPercentEncoding else {
            throw TextCodecError.invalidPercentEncoding
        }
        return decoded
    }

    private static func base64Decode(_ input: String, urlSafe: Bool) throws -> String {
        var normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !normalized.contains(where: { $0.isWhitespace }) else {
            throw TextCodecError.invalidBase64
        }
        if urlSafe {
            guard !normalized.contains("+"), !normalized.contains("/") else {
                throw TextCodecError.invalidBase64
            }
            normalized = normalized
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
        }
        let remainder = normalized.count % 4
        guard remainder != 1 else { throw TextCodecError.invalidBase64 }
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: normalized, options: []),
              !data.isEmpty else { throw TextCodecError.invalidBase64 }
        guard let output = String(data: data, encoding: .utf8) else {
            throw TextCodecError.nonTextBase64
        }
        return output
    }

    private static func base64Detection(_ input: String) -> TextCodecDetection? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12, !trimmed.contains(where: { $0.isWhitespace }) else {
            return nil
        }
        let isURLSafe = trimmed.contains("-") || trimmed.contains("_")
        let operation: TextTransformationOperation = isURLSafe
            ? .base64URLDecode
            : .base64Decode
        guard let output = try? transform(trimmed, operation: operation),
              output != input,
              printableRatio(output) >= 0.85 else { return nil }
        return TextCodecDetection(
            kind: isURLSafe ? .base64URL : .base64,
            operation: operation,
            output: output
        )
    }

    private static func printableRatio(_ text: String) -> Double {
        guard !text.unicodeScalars.isEmpty else { return 0 }
        let printable = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if !CharacterSet.controlCharacters.contains(scalar)
                || scalar == "\n" || scalar == "\r" || scalar == "\t" {
                count += 1
            }
        }
        return Double(printable) / Double(text.unicodeScalars.count)
    }

    private static func htmlEncode(_ input: String) -> String {
        var output = ""
        output.reserveCapacity(input.count)
        for character in input {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "'": output += "&apos;"
            default: output.append(character)
            }
        }
        return output
    }

    private static func htmlDecode(_ input: String) throws -> String {
        let pattern = #"&(?:#(?:[xX][0-9A-Fa-f]+|[0-9]+)|[A-Za-z][A-Za-z0-9]+);"#
        let regex = try NSRegularExpression(pattern: pattern)
        let source = input as NSString
        let matches = regex.matches(
            in: input,
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else { throw TextCodecError.invalidHTMLEntity(input) }
        let output = NSMutableString(string: input)
        for match in matches.reversed() {
            let entity = source.substring(with: match.range)
            guard let decoded = decodedHTMLEntity(entity) else {
                throw TextCodecError.invalidHTMLEntity(entity)
            }
            output.replaceCharacters(in: match.range, with: decoded)
        }
        return output as String
    }

    private static func decodedHTMLEntity(_ entity: String) -> String? {
        switch entity {
        case "&amp;": return "&"
        case "&lt;": return "<"
        case "&gt;": return ">"
        case "&quot;": return "\""
        case "&apos;": return "'"
        case "&nbsp;": return "\u{00A0}"
        case "&copy;": return "©"
        case "&reg;": return "®"
        case "&trade;": return "™"
        case "&hellip;": return "…"
        case "&ndash;": return "–"
        case "&mdash;": return "—"
        case "&lsquo;": return "‘"
        case "&rsquo;": return "’"
        case "&ldquo;": return "“"
        case "&rdquo;": return "”"
        case "&bull;": return "•"
        case "&euro;": return "€"
        case "&cent;": return "¢"
        case "&pound;": return "£"
        case "&yen;": return "¥"
        default: break
        }
        guard entity.hasPrefix("&#"), entity.hasSuffix(";") else { return nil }
        let body = String(entity.dropFirst(2).dropLast())
        let value: UInt32?
        if body.hasPrefix("x") || body.hasPrefix("X") {
            value = UInt32(body.dropFirst(), radix: 16)
        } else {
            value = UInt32(body, radix: 10)
        }
        guard let value, let scalar = UnicodeScalar(value) else { return nil }
        return String(scalar)
    }

    private static func unicodeEscape(_ input: String) -> String {
        var output = ""
        for scalar in input.unicodeScalars {
            switch scalar.value {
            case 0x08: output += #"\b"#
            case 0x09: output += #"\t"#
            case 0x0A: output += #"\n"#
            case 0x0C: output += #"\f"#
            case 0x0D: output += #"\r"#
            case 0x22: output += #"\""#
            case 0x5C: output += #"\\"#
            case 0x20...0x7E: output.append(Character(String(scalar)))
            case 0...0xFFFF:
                output += String(format: #"\u%04X"#, scalar.value)
            default:
                let value = scalar.value - 0x10000
                let high = 0xD800 + (value >> 10)
                let low = 0xDC00 + (value & 0x3FF)
                output += String(format: #"\u%04X\u%04X"#, high, low)
            }
        }
        return output
    }

    private static func unicodeUnescape(_ input: String) throws -> String {
        let scalars = Array(input.unicodeScalars)
        var output = ""
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "\\" else {
                output.unicodeScalars.append(scalars[index])
                index += 1
                continue
            }
            guard index + 1 < scalars.count else {
                throw TextCodecError.invalidUnicodeEscape("\\")
            }
            let marker = scalars[index + 1]
            switch marker {
            case "b": output.append("\u{08}"); index += 2
            case "t": output.append("\t"); index += 2
            case "n": output.append("\n"); index += 2
            case "f": output.append("\u{0C}"); index += 2
            case "r": output.append("\r"); index += 2
            case "\"": output.append("\""); index += 2
            case "\\": output.append("\\"); index += 2
            case "/": output.append("/"); index += 2
            case "u":
                let parsed = try parseUnicodeEscape(scalars, startingAt: index)
                if (0xD800...0xDBFF).contains(parsed.value) {
                    let next = parsed.nextIndex
                    guard next + 5 < scalars.count,
                          scalars[next] == "\\", scalars[next + 1] == "u" else {
                        throw TextCodecError.invalidUnicodeEscape("高位代理项缺少低位代理项")
                    }
                    let low = try parseUnicodeEscape(scalars, startingAt: next)
                    guard (0xDC00...0xDFFF).contains(low.value) else {
                        throw TextCodecError.invalidUnicodeEscape("代理项组合无效")
                    }
                    let combined = 0x10000
                        + ((parsed.value - 0xD800) << 10)
                        + (low.value - 0xDC00)
                    guard let scalar = UnicodeScalar(combined) else {
                        throw TextCodecError.invalidUnicodeEscape("Unicode 标量超出范围")
                    }
                    output.unicodeScalars.append(scalar)
                    index = low.nextIndex
                } else {
                    guard !(0xDC00...0xDFFF).contains(parsed.value),
                          let scalar = UnicodeScalar(parsed.value) else {
                        throw TextCodecError.invalidUnicodeEscape("Unicode 标量无效")
                    }
                    output.unicodeScalars.append(scalar)
                    index = parsed.nextIndex
                }
            default:
                throw TextCodecError.invalidUnicodeEscape("\\\(marker)")
            }
        }
        return output
    }

    private static func parseUnicodeEscape(
        _ scalars: [UnicodeScalar],
        startingAt index: Int
    ) throws -> (value: UInt32, nextIndex: Int) {
        guard index + 2 < scalars.count,
              scalars[index] == "\\", scalars[index + 1] == "u" else {
            throw TextCodecError.invalidUnicodeEscape("\\u")
        }
        if scalars[index + 2] == "{" {
            var cursor = index + 3
            var digits = ""
            while cursor < scalars.count, scalars[cursor] != "}" {
                digits.unicodeScalars.append(scalars[cursor])
                cursor += 1
            }
            guard cursor < scalars.count,
                  (1...8).contains(digits.count),
                  let value = UInt32(digits, radix: 16),
                  UnicodeScalar(value) != nil else {
                throw TextCodecError.invalidUnicodeEscape("\\u{\(digits)}")
            }
            return (value, cursor + 1)
        }
        guard index + 5 < scalars.count else {
            throw TextCodecError.invalidUnicodeEscape("不完整的 \\u 转义")
        }
        let digits = String(String.UnicodeScalarView(scalars[(index + 2)...(index + 5)]))
        guard digits.unicodeScalars.allSatisfy({ Character($0).isHexDigit }),
              let value = UInt32(digits, radix: 16) else {
            throw TextCodecError.invalidUnicodeEscape("\\u\(digits)")
        }
        return (value, index + 6)
    }

    private static func containsUnicodeEscape(_ input: String) -> Bool {
        input.range(of: #"\\u(?:\{[0-9A-Fa-f]{1,8}\}|[0-9A-Fa-f]{4})"#,
                    options: .regularExpression) != nil
    }

    private static func isWhitespace(_ codeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(codeUnit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func trimTokenPunctuation(in text: NSString, range: inout NSRange) {
        let leading: Set<unichar> = [0x22, 0x27, 0x60, 0x3C, 0x2C]
        let trailing: Set<unichar> = [0x22, 0x27, 0x60, 0x3E, 0x2C]
        while range.length > 0, leading.contains(text.character(at: range.location)) {
            range.location += 1
            range.length -= 1
        }
        while range.length > 0,
              trailing.contains(text.character(at: NSMaxRange(range) - 1)) {
            range.length -= 1
        }
    }
}
