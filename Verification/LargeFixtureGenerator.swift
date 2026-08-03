import Foundation

@main
enum LargeFixtureGenerator {
    private struct Fixture {
        let name: String
        let megabytes: Int
        let pattern: String
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Usage: large-fixture-generator <output-directory>")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fixtures = [
            Fixture(
                name: "short-lines-1mb.js",
                megabytes: 1,
                pattern: "const value = 12345; // LacEditor baseline\n"
            ),
            Fixture(
                name: "long-lines-10mb.log",
                megabytes: 10,
                pattern: String(repeating: "x", count: 8_192) + " marker\n"
            ),
            Fixture(
                name: "markdown-20mb.md",
                megabytes: 20,
                pattern: "## 性能标题\n\n- 列表项目\n- 包含 **强调** 与 `code`\n\n"
            ),
            Fixture(
                name: "json-50mb.json",
                megabytes: 50,
                pattern: "{\"name\":\"LacEditor\",\"enabled\":true,\"value\":12345}\n"
            ),
            Fixture(
                name: "best-effort-100mb.txt",
                megabytes: 100,
                pattern: "LacEditor 100 MB best-effort fixture\n"
            )
        ]
        for fixture in fixtures {
            try write(fixture, to: directory.appendingPathComponent(fixture.name))
        }
    }

    private static func write(_ fixture: Fixture, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let pattern = Data(fixture.pattern.utf8)
        let targetSize = fixture.megabytes * 1_024 * 1_024
        var remaining = targetSize
        while remaining > 0 {
            let count = min(remaining, pattern.count)
            try handle.write(contentsOf: pattern.prefix(count))
            remaining -= count
        }
    }
}
