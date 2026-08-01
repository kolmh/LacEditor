import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("Performance verification failed: \(message)")
    }
}

private func measure<T>(_ operation: () -> T) -> (value: T, seconds: Double) {
    let start = ProcessInfo.processInfo.systemUptime
    let value = operation()
    return (value, ProcessInfo.processInfo.systemUptime - start)
}

@main
struct PerformanceVerification {
    static func main() {
        let line = "const value = 12345; // LacEditor performance baseline\n"
        let source = String(repeating: line, count: 80_000)
        let sourceLength = (source as NSString).length
        require(source.utf8.count >= 4_000_000, "fixture must be at least 4 MB")

        let indexResult = measure { LogicalLineIndex(text: source) }
        let finalPosition = indexResult.value.position(
            at: sourceLength,
            in: source as NSString
        )
        require(finalPosition.line == 80_001, "large-file line index result")
        require(indexResult.seconds < 5, "line index took \(indexResult.seconds)s")

        let searchResult = measure {
            TextSearchService.nextRange(
                in: source,
                query: "performance baseline",
                after: NSRange(location: sourceLength / 2, length: 0),
                caseSensitive: true
            )
        }
        require(searchResult.value != nil, "large-file search result")
        require(searchResult.seconds < 3, "large-file search took \(searchResult.seconds)s")

        let visibleStart = sourceLength / 2
        let highlightResult = measure {
            SyntaxHighlighter.tokens(
                in: source,
                language: .javascript,
                range: NSRange(location: visibleStart, length: 12_000)
            )
        }
        require(!highlightResult.value.isEmpty, "visible-range syntax tokens")
        require(highlightResult.seconds < 3, "visible-range highlighting took \(highlightResult.seconds)s")

        let markdown = String(
            repeating: "## 标题\n\n段落包含 **强调** 和 [链接](https://example.com)。\n\n",
            count: 2_000
        )
        let previewResult = measure {
            MarkdownRenderer.render(markdown, darkMode: false)
        }
        require(previewResult.value.contains("<h2>标题</h2>"), "large Markdown render result")
        require(previewResult.seconds < 5, "Markdown rendering took \(previewResult.seconds)s")

        print(String(format: "Performance verification passed: index %.3fs, search %.3fs, highlight %.3fs, Markdown %.3fs", indexResult.seconds, searchResult.seconds, highlightResult.seconds, previewResult.seconds))
    }
}
