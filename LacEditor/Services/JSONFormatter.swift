import Foundation

enum JSONFormatter {
    static func format(
        _ text: String,
        pretty: Bool,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> String {
        var formatter = OrderedJSONFormatter(
            text: text,
            pretty: pretty,
            isCancelled: isCancelled
        )
        return try formatter.format()
    }

    static func userFacingError(_ error: Error, in text: String) -> String {
        if error is CancellationError { return "JSON 操作已取消" }
        let nsError = error as NSError
        let description = nsError.localizedDescription
        if let debugDescription = nsError.userInfo["NSDebugDescription"] as? String,
           let location = lineAndColumn(from: debugDescription) {
            return "JSON 无效：第 \(location.line) 行，第 \(location.column + 1) 列。\(description)"
        }
        if let location = lineAndColumn(from: description) {
            return "JSON 无效：第 \(location.line) 行，第 \(location.column) 列。\(description)"
        }
        if let index = nsError.userInfo["NSJSONSerializationErrorIndex"] as? Int {
            return message(forByteIndex: index, description: description, in: text)
        }
        if let index = byteIndex(from: description) {
            return message(forByteIndex: index, description: description, in: text)
        }
        return "JSON 无效：\(description)"
    }

    private static func message(
        forByteIndex index: Int,
        description: String,
        in text: String
    ) -> String {
        let prefix = text.utf8.prefix(max(0, index))
        let decodedPrefix = String(decoding: prefix, as: UTF8.self)
        let line = decodedPrefix.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
        let column = decodedPrefix.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).last?.count ?? 0
        return "JSON 无效：第 \(line) 行，第 \(column + 1) 列。\(description)"
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

private struct OrderedJSONFormatter {
    private static let maximumDepth = 512
    private static let cancellationStride = 4_096

    private let input: [UInt8]
    private let pretty: Bool
    private let isCancelled: () -> Bool
    private var output: [UInt8]
    private var index = 0
    private var nextCancellationCheck = 0

    init(text: String, pretty: Bool, isCancelled: @escaping () -> Bool) {
        input = Array(text.utf8)
        self.pretty = pretty
        self.isCancelled = isCancelled
        output = []
        output.reserveCapacity(text.utf8.count + min(text.utf8.count / 4, 1_048_576))
    }

    mutating func format() throws -> String {
        try checkCancellation(force: true)
        try skipWhitespace()
        guard index < input.count else { throw syntaxError("内容为空") }
        try parseValue(depth: 0)
        try skipWhitespace()
        guard index == input.count else { throw syntaxError("值后存在多余内容") }
        if pretty { output.append(.lineFeed) }
        return String(decoding: output, as: UTF8.self)
    }

    private mutating func parseValue(depth: Int) throws {
        try checkCancellation()
        guard depth <= Self.maximumDepth else {
            throw syntaxError("嵌套层级超过 \(Self.maximumDepth) 层")
        }
        try skipWhitespace()
        guard let byte = currentByte else { throw syntaxError("缺少 JSON 值") }
        switch byte {
        case .leftBrace:
            try parseObject(depth: depth)
        case .leftBracket:
            try parseArray(depth: depth)
        case .quote:
            try copyString()
        case .minus, .zero ... .nine:
            try copyNumber()
        case .lowerT:
            try copyLiteral([.lowerT, .lowerR, .lowerU, .lowerE], name: "true")
        case .lowerF:
            try copyLiteral([.lowerF, .lowerA, .lowerL, .lowerS, .lowerE], name: "false")
        case .lowerN:
            try copyLiteral([.lowerN, .lowerU, .lowerL, .lowerL], name: "null")
        default:
            throw syntaxError("此处应为 JSON 值")
        }
    }

    private mutating func parseObject(depth: Int) throws {
        output.append(.leftBrace)
        index += 1
        try skipWhitespace()
        if consume(.rightBrace) {
            output.append(.rightBrace)
            return
        }
        if pretty { output.append(.lineFeed) }

        var isFirst = true
        while true {
            try checkCancellation()
            if !isFirst {
                guard consume(.comma) else { throw syntaxError("对象成员之间缺少逗号") }
                output.append(.comma)
                if pretty { output.append(.lineFeed) }
                try skipWhitespace()
                guard currentByte != .rightBrace else { throw syntaxError("对象末尾不允许多余逗号") }
            }
            if pretty { appendIndent(depth + 1) }
            guard currentByte == .quote else { throw syntaxError("对象字段名必须是字符串") }
            try copyString()
            try skipWhitespace()
            guard consume(.colon) else { throw syntaxError("字段名后缺少冒号") }
            if pretty {
                output.append(.space)
                output.append(.colon)
                output.append(.space)
            } else {
                output.append(.colon)
            }
            try parseValue(depth: depth + 1)
            try skipWhitespace()
            if consume(.rightBrace) {
                if pretty {
                    output.append(.lineFeed)
                    appendIndent(depth)
                }
                output.append(.rightBrace)
                return
            }
            isFirst = false
        }
    }

    private mutating func parseArray(depth: Int) throws {
        output.append(.leftBracket)
        index += 1
        try skipWhitespace()
        if consume(.rightBracket) {
            output.append(.rightBracket)
            return
        }
        if pretty { output.append(.lineFeed) }

        var isFirst = true
        while true {
            try checkCancellation()
            if !isFirst {
                guard consume(.comma) else { throw syntaxError("数组元素之间缺少逗号") }
                output.append(.comma)
                if pretty { output.append(.lineFeed) }
                try skipWhitespace()
                guard currentByte != .rightBracket else { throw syntaxError("数组末尾不允许多余逗号") }
            }
            if pretty { appendIndent(depth + 1) }
            try parseValue(depth: depth + 1)
            try skipWhitespace()
            if consume(.rightBracket) {
                if pretty {
                    output.append(.lineFeed)
                    appendIndent(depth)
                }
                output.append(.rightBracket)
                return
            }
            isFirst = false
        }
    }

    private mutating func copyString() throws {
        let start = index
        index += 1
        while index < input.count {
            try checkCancellation()
            let byte = input[index]
            switch byte {
            case .quote:
                index += 1
                output.append(contentsOf: input[start..<index])
                return
            case .backslash:
                index += 1
                guard index < input.count else { throw syntaxError("字符串转义不完整") }
                let escaped = input[index]
                if escaped == .lowerU {
                    guard index + 4 < input.count else { throw syntaxError("Unicode 转义不完整") }
                    for hexIndex in (index + 1)...(index + 4) where !input[hexIndex].isHexDigit {
                        index = hexIndex
                        throw syntaxError("Unicode 转义包含无效字符")
                    }
                    index += 5
                } else if escaped.isSimpleJSONEscape {
                    index += 1
                } else {
                    throw syntaxError("字符串包含无效转义")
                }
            case 0x00...0x1F:
                throw syntaxError("字符串包含未转义的控制字符")
            default:
                index += 1
            }
        }
        throw syntaxError("字符串缺少结束引号")
    }

    private mutating func copyNumber() throws {
        let start = index
        if consume(.minus) {
            guard currentByte != nil else { throw syntaxError("负号后缺少数字") }
        }

        if consume(.zero) {
            if let byte = currentByte, byte.isDigit {
                throw syntaxError("数字不允许包含前导零")
            }
        } else {
            guard let byte = currentByte, byte.isOneThroughNine else {
                throw syntaxError("数字的整数部分无效")
            }
            try copyDigits()
        }

        if consume(.period) {
            guard currentByte?.isDigit == true else { throw syntaxError("小数点后缺少数字") }
            try copyDigits()
        }

        if currentByte == .lowerE || currentByte == .upperE {
            index += 1
            if currentByte == .plus || currentByte == .minus { index += 1 }
            guard currentByte?.isDigit == true else { throw syntaxError("指数部分缺少数字") }
            try copyDigits()
        }
        output.append(contentsOf: input[start..<index])
    }

    private mutating func copyLiteral(_ literal: [UInt8], name: String) throws {
        guard index + literal.count <= input.count,
              input[index..<(index + literal.count)].elementsEqual(literal) else {
            throw syntaxError("无效的 \(name) 字面量")
        }
        output.append(contentsOf: literal)
        index += literal.count
    }

    private mutating func copyDigits() throws {
        while currentByte?.isDigit == true {
            index += 1
            try checkCancellation()
        }
    }

    private mutating func skipWhitespace() throws {
        while currentByte?.isJSONWhitespace == true {
            index += 1
            try checkCancellation()
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard currentByte == byte else { return false }
        index += 1
        return true
    }

    private mutating func appendIndent(_ depth: Int) {
        output.append(contentsOf: repeatElement(.space, count: depth * 2))
    }

    private mutating func checkCancellation(force: Bool = false) throws {
        guard force || index >= nextCancellationCheck else { return }
        if isCancelled() { throw CancellationError() }
        nextCancellationCheck = index + Self.cancellationStride
    }

    private var currentByte: UInt8? {
        index < input.count ? input[index] : nil
    }

    private func syntaxError(_ description: String) -> NSError {
        NSError(
            domain: "LacEditor.JSONFormatter",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: description,
                "NSJSONSerializationErrorIndex": min(index, input.count)
            ]
        )
    }
}

private extension UInt8 {
    static let backslash: UInt8 = 0x5C
    static let colon: UInt8 = 0x3A
    static let comma: UInt8 = 0x2C
    static let leftBrace: UInt8 = 0x7B
    static let leftBracket: UInt8 = 0x5B
    static let lineFeed: UInt8 = 0x0A
    static let lowerA: UInt8 = 0x61
    static let lowerE: UInt8 = 0x65
    static let lowerF: UInt8 = 0x66
    static let lowerL: UInt8 = 0x6C
    static let lowerN: UInt8 = 0x6E
    static let lowerR: UInt8 = 0x72
    static let lowerS: UInt8 = 0x73
    static let lowerT: UInt8 = 0x74
    static let lowerU: UInt8 = 0x75
    static let minus: UInt8 = 0x2D
    static let nine: UInt8 = 0x39
    static let period: UInt8 = 0x2E
    static let plus: UInt8 = 0x2B
    static let quote: UInt8 = 0x22
    static let rightBrace: UInt8 = 0x7D
    static let rightBracket: UInt8 = 0x5D
    static let space: UInt8 = 0x20
    static let upperE: UInt8 = 0x45
    static let zero: UInt8 = 0x30

    var isDigit: Bool { self >= 0x30 && self <= 0x39 }
    var isOneThroughNine: Bool { self >= 0x31 && self <= 0x39 }
    var isHexDigit: Bool {
        isDigit || (self >= 0x41 && self <= 0x46) || (self >= 0x61 && self <= 0x66)
    }
    var isJSONWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
    var isSimpleJSONEscape: Bool {
        self == 0x22 || self == 0x5C || self == 0x2F || self == 0x62
            || self == 0x66 || self == 0x6E || self == 0x72 || self == 0x74
    }
}
