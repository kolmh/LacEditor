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
          li { margin: .25em 0; }
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
        let lines = markdown.components(separatedBy: .newlines)
        var output: [String] = []
        var paragraph: [String] = []
        var listType: String?
        var inCodeBlock = false
        var codeLines: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            output.append("<p>\(inline(paragraph.joined(separator: " ")))</p>")
            paragraph.removeAll()
        }

        func closeList() {
            guard let openListType = listType else { return }
            output.append("</\(openListType)>")
            listType = nil
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                closeList()
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
                closeList()
                index += 1
                continue
            }

            if index + 1 < lines.count,
               line.contains("|"),
               isTableDivider(lines[index + 1]) {
                flushParagraph()
                closeList()
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
                closeList()
                output.append("<h\(heading.level)>\(inline(heading.text))</h\(heading.level)>")
            } else if trimmed.range(of: #"^([-*_])(?:\s*\1){2,}$"#, options: .regularExpression) != nil {
                flushParagraph()
                closeList()
                output.append("<hr>")
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                closeList()
                let value = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                output.append("<blockquote>\(inline(value))</blockquote>")
            } else if let item = listItem(trimmed) {
                flushParagraph()
                if listType != item.type {
                    closeList()
                    listType = item.type
                    if item.type == "ol", let start = item.start {
                        output.append("<ol start=\"\(start)\">")
                    } else {
                        output.append("<\(item.type)>")
                    }
                }
                output.append("<li>\(inline(item.text))</li>")
            } else {
                closeList()
                paragraph.append(line)
            }
            index += 1
        }

        if inCodeBlock {
            output.append("<pre><code>\(escape(codeLines.joined(separator: "\n")))</code></pre>")
        }
        flushParagraph()
        closeList()
        return output.joined(separator: "\n")
    }

    private static func inline(_ value: some StringProtocol) -> String {
        var result = escape(String(value))
        let replacements: [(String, String)] = [
            (#"`([^`\n]+)`"#, "<code>$1</code>"),
            (#"\[([^\]]+)\]\(([^)]+)\)"#, #"<a href="$2">$1</a>"#),
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

    private static func listItem(_ line: String) -> (type: String, text: String, start: Int?)? {
        if let range = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
            return ("ul", String(line[range.upperBound...]), nil)
        }
        if let range = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            let marker = line[..<range.upperBound]
            let number = Int(marker.prefix { $0.isNumber })
            return ("ol", String(line[range.upperBound...]), number)
        }
        return nil
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
