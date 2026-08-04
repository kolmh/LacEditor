import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("Large-file verification failed: \(message)") }
}

@main
enum LargeFileIOVerification {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Usage: large-file-verification <fixture-directory>")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixtures: [(String, Int, DocumentPerformanceProfile, Double)] = [
            ("short-lines-1mb.js", 1, .standard, 2.5),
            ("long-lines-10mb.log", 10, .standard, 2.5),
            ("markdown-20mb.md", 20, .large, 2.5),
            ("json-50mb.json", 50, .large, 2.5),
            ("best-effort-100mb.txt", 100, .extreme, 6.0)
        ]

        for (name, megabytes, expectedProfile, limit) in fixtures {
            let url = directory.appendingPathComponent(name)
            let start = ProcessInfo.processInfo.systemUptime
            let prepared = try FileService.prepareRead(url)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            guard case let .decoded(decoded) = prepared else {
                fatalError("Large-file verification failed: UTF-8 fixture requested encoding")
            }
            require(decoded.byteCount == megabytes * 1_024 * 1_024, "\(name) byte count")
            let profile = DocumentPerformanceProfile.resolve(
                byteCount: decoded.byteCount,
                lineCount: decoded.lineCount
            )
            require(profile == expectedProfile, "\(name) profile was \(profile)")
            require(elapsed < limit, "\(name) decode took \(elapsed)s")

            if megabytes == 1 || megabytes == 10 {
                let wrapped = "{\n" + decoded.text + "\n}"
                let delimiterStart = ProcessInfo.processInfo.systemUptime
                let delimiterMatch = DelimiterMatchingService.match(
                    in: wrapped,
                    selection: NSRange(location: 0, length: 0),
                    language: .javascript,
                    revision: 0,
                    context: .init()
                )
                let delimiterElapsed = ProcessInfo.processInfo.systemUptime
                    - delimiterStart
                require(
                    delimiterMatch?.closingRange.location
                        == (wrapped as NSString).length - 1,
                    "\(megabytes) MB distant delimiter result"
                )
                require(
                    delimiterElapsed < 1.5,
                    "\(megabytes) MB delimiter match took \(delimiterElapsed)s"
                )
            }

            if megabytes == 50 {
                let searchStart = ProcessInfo.processInfo.systemUptime
                let match = TextSearchService.previousRange(
                    in: decoded.text,
                    query: "LacEditor",
                    before: NSRange(location: (decoded.text as NSString).length, length: 0),
                    caseSensitive: true
                )
                let searchElapsed = ProcessInfo.processInfo.systemUptime - searchStart
                require(match != nil, "50 MB search result")
                require(searchElapsed < 1.5, "50 MB search took \(searchElapsed)s")

                let text = decoded.text as NSString
                let delimiterContext = DelimiterMatchingService.Context()
                let delimiterStart = ProcessInfo.processInfo.systemUptime
                var matchedCount = 0
                for sample in 0..<100 {
                    let approximate = min(
                        text.length - 1,
                        (text.length * sample) / 100
                    )
                    let range = text.range(
                        of: "{",
                        options: [],
                        range: NSRange(
                            location: approximate,
                            length: text.length - approximate
                        )
                    )
                    guard range.location != NSNotFound else { continue }
                    if DelimiterMatchingService.match(
                        in: decoded.text,
                        selection: range,
                        language: .json,
                        revision: 0,
                        context: delimiterContext
                    ) != nil {
                        matchedCount += 1
                    }
                }
                let delimiterElapsed = ProcessInfo.processInfo.systemUptime
                    - delimiterStart
                require(matchedCount == 100, "50 MB repeated delimiter results")
                require(
                    delimiterElapsed < 4,
                    "50 MB 100 delimiter moves took \(delimiterElapsed)s"
                )
            }
            print(String(format: "%@ decoded in %.3fs", name, elapsed))
        }
    }
}
