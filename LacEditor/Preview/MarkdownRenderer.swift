import Foundation

enum MarkdownRenderer {
    static func render(_ markdown: String, darkMode: Bool) -> String {
        let body = renderBlocks(markdown)
        let foreground = darkMode ? "#d7d7dc" : "#29292d"
        let secondary = darkMode ? "#aaaab2" : "#64646c"
        let border = darkMode ? "#3a3a40" : "#dedee3"
        let codeBackground = darkMode ? "#25252a" : "#f3f3f5"
        let accent = darkMode ? "#aeb6ff" : "#4d55a7"
        let background = darkMode ? "#1e1e22" : "#fbfbfb"

        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: \(darkMode ? "dark" : "light"); }
          * { box-sizing: border-box; }
          body {
            margin: 0; padding: 30px 38px 64px; background: \(background); color: \(foreground);
            font: 15px/1.72 -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
            overflow-wrap: anywhere;
          }
          article { max-width: 760px; margin: 0 auto; }
          h1, h2, h3, h4, h5, h6 { line-height: 1.28; margin: 1.45em 0 .55em; font-weight: 650; }
          h1 { font-size: 2em; margin-top: .25em; }
          h2 { font-size: 1.5em; border-bottom: 1px solid \(border); padding-bottom: .32em; }
          h3 { font-size: 1.22em; }
          p { margin: .8em 0; }
          ul, ol { padding-left: 1.6em; }
          ul { list-style-type: disc; }
          ul ul { list-style-type: circle; }
          ul ul ul { list-style-type: square; }
          ol { list-style-type: decimal; }
          ol ol { list-style-type: lower-alpha; }
          ol ol ol { list-style-type: lower-roman; }
          li { margin: .25em 0; }
          li > ul, li > ol { margin-top: .25em; margin-bottom: .25em; }
          blockquote { margin: 1em 0; padding: .15em 1em; color: \(secondary); border-left: 3px solid \(border); }
          hr { border: 0; border-top: 1px solid \(border); margin: 1.8em 0; }
          a { color: \(accent); text-decoration: none; }
          code { font: .9em ui-monospace, SFMono-Regular, Menlo, monospace; background: \(codeBackground); padding: .12em .32em; border-radius: 3px; }
          pre { overflow: auto; background: \(codeBackground); border: 1px solid \(border); padding: 14px 16px; border-radius: 5px; }
          pre code { background: none; padding: 0; }
          table { width: 100%; border-collapse: collapse; margin: 1.2em 0; }
          th, td { border: 1px solid \(border); padding: .48em .7em; text-align: left; }
          th { font-weight: 600; background: \(codeBackground); }
        </style>
        </head>
        <body><article>\(body)</article></body>
        </html>
        """
    }

    private static func renderBlocks(_ markdown: String) -> String {
        let normalizedMarkdown = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        let lines = normalizedMarkdown.components(separatedBy: "\n")
        var output: [String] = []
        var paragraph: [String] = []
        var inCodeBlock = false
        var codeLines: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            output.append("<p>\(inline(paragraph.joined(separator: " ")))</p>")
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                if inCodeBlock {
                    output.append("<pre><code>\(escape(codeLines.joined(separator: "\n")))</code></pre>")
                    codeLines.removeAll()
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                }
                index += 1
                continue
            }
            if inCodeBlock {
                codeLines.append(line)
                index += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if index + 1 < lines.count,
               line.contains("|"),
                isTableDivider(lines[index + 1]) {
                flushParagraph()
                let headers = tableCells(line)
                output.append("<table><thead><tr>\(headers.map { "<th>\(inline($0))</th>" }.joined())</tr></thead><tbody>")
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    let cells = tableCells(lines[index])
                    output.append("<tr>\(cells.map { "<td>\(inline($0))</td>" }.joined())</tr>")
                    index += 1
                }
                output.append("</tbody></table>")
                continue
            }

            if let heading = headingParts(trimmed) {
                flushParagraph()
                output.append("<h\(heading.level)>\(inline(heading.text))</h\(heading.level)>")
            } else if trimmed.range(of: #"^([-*_])(?:\s*\1){2,}$"#, options: .regularExpression) != nil {
                flushParagraph()
                output.append("<hr>")
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                let value = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                output.append("<blockquote>\(inline(value))</blockquote>")
            } else if let item = listItem(line) {
                flushParagraph()
                let block = parseListBlock(
                    lines,
                    index: &index,
                    indent: item.indent,
                    type: item.type
                )
                output.append(renderListBlock(block))
                continue
            } else {
                paragraph.append(line)
            }
            index += 1
        }

        if inCodeBlock {
            output.append("<pre><code>\(escape(codeLines.joined(separator: "\n")))</code></pre>")
        }
        flushParagraph()
        return output.joined(separator: "\n")
    }

    private struct ParsedListItem {
        let indent: Int
        let type: String
        let text: String
        let number: Int?
    }

    private struct ListEntry {
        var textLines: [String]
        let number: Int?
        var children: [ListBlock] = []
    }

    private struct ListBlock {
        let type: String
        let start: Int?
        var items: [ListEntry]
    }

    private static func parseListBlock(
        _ lines: [String],
        index: inout Int,
        indent: Int,
        type: String
    ) -> ListBlock {
        var block = ListBlock(type: type, start: nil, items: [])

        while index < lines.count,
              let item = listItem(lines[index]),
              item.indent == indent,
              item.type == type {
            if block.items.isEmpty {
                block = ListBlock(type: type, start: item.number, items: [])
            }
            block.items.append(ListEntry(textLines: [item.text], number: item.number))
            index += 1

            while index < lines.count {
                if let child = listItem(lines[index]), child.indent > indent {
                    let childBlock = parseListBlock(
                        lines,
                        index: &index,
                        indent: child.indent,
                        type: child.type
                    )
                    block.items[block.items.count - 1].children.append(childBlock)
                    continue
                }

                guard listItem(lines[index]) == nil,
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                      indentationWidth(of: lines[index]) > indent else {
                    break
                }
                block.items[block.items.count - 1].textLines.append(
                    lines[index].trimmingCharacters(in: .whitespaces)
                )
                index += 1
            }
        }

        return block
    }

    private static func renderListBlock(_ block: ListBlock) -> String {
        let opening: String
        if block.type == "ol", let start = block.start, start != 1 {
            opening = "<ol start=\"\(start)\">"
        } else {
            opening = "<\(block.type)>"
        }

        var output = [opening]
        var expectedNumber = block.start ?? 1
        for item in block.items {
            let valueAttribute: String
            if block.type == "ol",
               let number = item.number,
               number != expectedNumber {
                valueAttribute = " value=\"\(number)\""
                expectedNumber = number
            } else {
                valueAttribute = ""
            }

            let text = inline(item.textLines.joined(separator: " "))
            if item.children.isEmpty {
                output.append("<li\(valueAttribute)>\(text)</li>")
            } else {
                let children = item.children.map(renderListBlock).joined(separator: "\n")
                output.append("<li\(valueAttribute)>\(text)\n\(children)\n</li>")
            }
            expectedNumber += 1
        }
        output.append("</\(block.type)>")
        return output.joined(separator: "\n")
    }

    private static func inline(_ value: some StringProtocol) -> String {
        var result = escape(String(value))
        var inlineCodeSegments: [String] = []
        var placeholderPrefix = "LACXINCODEX"
        while result.contains(placeholderPrefix) {
            placeholderPrefix.append("X")
        }
        if let codeRegex = try? NSRegularExpression(pattern: #"`([^`\n]+)`"#) {
            let matches = codeRegex.matches(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length)
            )
            let mutable = NSMutableString(string: result)
            for match in matches.reversed() {
                let code = (result as NSString).substring(with: match.range(at: 1))
                let index = inlineCodeSegments.count
                inlineCodeSegments.append("<code>\(code)</code>")
                mutable.replaceCharacters(
                    in: match.range,
                    with: "\(placeholderPrefix)\(index)XENDLAC"
                )
            }
            result = mutable as String
        }
        var linkSegments: [String] = []
        var linkPlaceholderPrefix = "LACXLINKX"
        while result.contains(linkPlaceholderPrefix) {
            linkPlaceholderPrefix.append("X")
        }
        if let linkRegex = try? NSRegularExpression(
            pattern: #"\[([^\]]+)\]\(([^)]+)\)"#
        ) {
            let matches = linkRegex.matches(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length)
            )
            let mutable = NSMutableString(string: result)
            for match in matches.reversed() {
                let label = (result as NSString).substring(with: match.range(at: 1))
                let destination = (result as NSString).substring(with: match.range(at: 2))
                let index = linkSegments.count
                linkSegments.append("<a href=\"\(destination)\">\(label)</a>")
                mutable.replaceCharacters(
                    in: match.range,
                    with: "\(linkPlaceholderPrefix)\(index)XENDLAC"
                )
            }
            result = mutable as String
        }
        let replacements: [(String, String)] = [
            (#"\*\*([^*\n]+)\*\*"#, "<strong>$1</strong>"),
            (#"__([^_\n]+)__"#, "<strong>$1</strong>"),
            (#"(?<!\*)\*([^*\n]+)\*(?!\*)"#, "<em>$1</em>"),
            (#"(?<!_)_([^_\n]+)_(?!_)"#, "<em>$1</em>")
        ]
        for (pattern, template) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        for (index, segment) in linkSegments.enumerated() {
            result = result.replacingOccurrences(
                of: "\(linkPlaceholderPrefix)\(index)XENDLAC",
                with: segment
            )
        }
        for (index, segment) in inlineCodeSegments.enumerated() {
            result = result.replacingOccurrences(
                of: "\(placeholderPrefix)\(index)XENDLAC",
                with: segment
            )
        }
        return result
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func headingParts(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6,
              line.dropFirst(hashes.count).first == " " else { return nil }
        return (hashes.count, line.dropFirst(hashes.count + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> ParsedListItem? {
        let indent = indentationWidth(of: line)
        let content = line.dropFirst(line.prefix { $0 == " " || $0 == "\t" }.count)
        if let range = content.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
            return ParsedListItem(
                indent: indent,
                type: "ul",
                text: String(content[range.upperBound...]),
                number: nil
            )
        }
        if let range = content.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            let marker = content[..<range.upperBound]
            let number = Int(marker.prefix { $0.isNumber })
            return ParsedListItem(
                indent: indent,
                type: "ol",
                text: String(content[range.upperBound...]),
                number: number
            )
        }
        return nil
    }

    private static func indentationWidth(of line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " {
                width += 1
            } else if character == "\t" {
                width += 4 - (width % 4)
            } else {
                break
            }
        }
        return width
    }

    private static func isTableDivider(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces)
            .range(of: #"^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?$"#, options: .regularExpression) != nil
    }

    private static func tableCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

}
