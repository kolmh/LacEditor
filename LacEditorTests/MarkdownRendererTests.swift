import Foundation
import XCTest
@testable import LacEditor

final class MarkdownRendererTests: XCTestCase {
    func testCommonMarkBlocksAndLooseLists() {
        let html = MarkdownRenderer.render(
            """
            标题
            ====

            > 第一段
            >
            > 第二段

            1) 第一项

               第一项的续行段落。

            2) 第二项
               - 子项
                 跨行内容
            """,
            darkMode: false
        )

        XCTAssertTrue(html.contains("<h1>标题</h1>"))
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("<p>第一段</p>"))
        XCTAssertTrue(html.contains("<p>第二段</p>"))
        XCTAssertTrue(html.contains("<ol>"))
        XCTAssertTrue(html.contains("<p>第一项</p>"))
        XCTAssertTrue(html.contains("<p>第一项的续行段落。</p>"))
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("子项"))
        XCTAssertTrue(html.contains("跨行内容"))
    }

    func testGFMExtensionsAndEscapedTableCells() {
        let html = MarkdownRenderer.render(
            """
            | 名称 | 状态 |
            | :--- | ---: |
            | Lac \\| Editor | ~~旧值~~ |

            - [x] 已完成
            - [ ] 未完成

            https://example.com/path
            """,
            darkMode: false
        )

        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("Lac | Editor"))
        XCTAssertTrue(html.contains("<del>旧值</del>"))
        XCTAssertTrue(html.contains("type=\"checkbox\""))
        XCTAssertTrue(html.contains("checked=\"\""))
        XCTAssertTrue(html.contains("href=\"https://example.com/path\""))
    }

    func testInlineMarkupEscapingAndRawHTMLSafety() {
        let html = MarkdownRenderer.render(
            """
            `**保持原样** [链接](https://example.com)`

            [带下划线的链接](https://example.com/foo_bar_baz)

            <script>alert('blocked')</script>

            [危险链接](javascript:alert(1))
            """,
            darkMode: false
        )

        XCTAssertTrue(html.contains("<code>**保持原样** [链接](https://example.com)</code>"))
        XCTAssertTrue(html.contains("href=\"https://example.com/foo_bar_baz\""))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("href=\"javascript:"))
    }

    func testCRLFAndUnicodeContent() {
        let html = MarkdownRenderer.render(
            "第一行\r\n第二行 😀",
            darkMode: false
        )
        XCTAssertTrue(html.contains("第一行"))
        XCTAssertTrue(html.contains("第二行 😀"))
        XCTAssertFalse(html.contains("第一行<br />\n<br />"))
    }

    func testSingleNewlineRendersAsVisibleBreak() {
        let html = MarkdownRenderer.render("第一行\n第二行", darkMode: false)
        XCTAssertTrue(html.contains("第一行<br") || html.contains("第一行\n第二行"))
        XCTAssertFalse(html.contains("<p>第一行 第二行</p>"))
    }

    func testHardBreaksDoNotDamageCodeBlocksOrLists() {
        let html = MarkdownRenderer.render(
            """
            - 第一项
              续行

            ```js
            const value = 1;
            console.log(value);
            ```
            """,
            darkMode: false
        )
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("const value = 1;"))
        XCTAssertTrue(html.contains("console.log(value);"))
    }

    func testMarkdownRenderingPerformanceGate() {
        let markdown = String(
            repeating: "## 标题\n\n段落包含 **强调** 和 [链接](https://example.com)。\n\n",
            count: 2_000
        )
        let start = ProcessInfo.processInfo.systemUptime
        let html = MarkdownRenderer.render(markdown, darkMode: false)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        XCTAssertTrue(html.contains("<h2>标题</h2>"))
        XCTAssertLessThan(elapsed, 5, "Markdown rendering took \(elapsed)s")
    }
}
