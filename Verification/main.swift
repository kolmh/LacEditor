import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("Verification failed: \(message)")
    }
}

do {
    let pretty = try JSONFormatter.format(#"{"name":"LacEditor","enabled":true}"#, pretty: true)
    require(pretty.contains(#""enabled" : true"#), "pretty JSON output")
    require(pretty.hasSuffix("\n"), "pretty JSON trailing newline")

    let compact = try JSONFormatter.format(#"{ "items": [1, 2, 3] }"#, pretty: false)
    require(compact == #"{"items":[1,2,3]}"#, "compact JSON output")

    do {
        _ = try JSONFormatter.format(#"{"broken": }"#, pretty: true)
        fatalError("Verification failed: invalid JSON was accepted")
    } catch {
        require(
            JSONFormatter.userFacingError(error, in: #"{"broken": }"#).hasPrefix("JSON 无效："),
            "invalid JSON message"
        )
    }
} catch {
    fatalError("Verification failed: JSON formatter threw \(error)")
}

let markdown = """
# 标题

> 引用

| 名称 | 值 |
| --- | --- |
| LacEditor | **轻量** |
"""
let html = MarkdownRenderer.render(markdown, darkMode: false)
require(html.contains("<h1>标题</h1>"), "Markdown heading")
require(html.contains("<blockquote>引用</blockquote>"), "Markdown quote")
require(html.contains("<table>"), "Markdown table")
require(html.contains("<strong>轻量</strong>"), "Markdown emphasis")

let orderedMarkdown = """
1. 第一项
2. 第二项
   - 子项 A
   - 子项 B
3. 第三项
4. 第四项
5. 第五项
"""
let orderedHTML = MarkdownRenderer.render(orderedMarkdown, darkMode: false)
require(orderedHTML.contains(#"<ol start="3">"#), "ordered list resumes at explicit number")
require(orderedHTML.contains("<li>第五项</li>"), "ordered list keeps later items")

require(EditorLanguage.infer(from: URL(fileURLWithPath: "script.js")) == .javascript, "JS language inference")
require(EditorLanguage.infer(from: URL(fileURLWithPath: "module.mjs")) == .javascript, "MJS language inference")
require(EditorLanguage.infer(from: URL(fileURLWithPath: "common.cjs")) == .javascript, "CJS language inference")
require(EditorLanguage.infer(from: URL(fileURLWithPath: "app.tsx")) == .typescript, "TSX language inference")
require(EditorLanguage.infer(from: URL(fileURLWithPath: "theme.css")) == .css, "CSS language inference")
require(EditorLanguage.infer(from: URL(fileURLWithPath: "tool.py")) == .python, "Python language inference")
require(EditorLanguage.infer(from: URL(fileURLWithPath: "View.swift")) == .swift, "Swift language inference")
require(EditorLanguage.infer(from: URL(fileURLWithPath: "build.zsh")) == .shell, "Shell language inference")
require(EditorLanguage.infer(from: URL(fileURLWithPath: "config.yml")) == .yaml, "YAML language inference")
require(EditorLanguage.infer(from: URL(fileURLWithPath: "engine.cpp")) == .cFamily, "C++ language inference")
require(EditorLanguage.infer(from: URL(fileURLWithPath: "schema.sql")) == .sql, "SQL language inference")

require(
    ListContinuationService.continuation(for: "9. 第九项") == "10. ",
    "ordered list continuation"
)
require(
    ListContinuationService.continuation(for: "  3) 第三项") == "4) ",
    "ordered list continuation with indentation and parenthesis"
)
require(
    ListContinuationService.continuation(for: "  + 子项") == "+ ",
    "unordered list marker continuation"
)
require(ListContinuationService.isEmptyListItem("  4. "), "empty ordered list detection")
require(ListContinuationService.continuation(for: "4. ") == nil, "empty list does not continue")

let deletedMiddleItem = """
1. 第一项
3. 第三项
4. 第四项
"""
let deletedMiddleNormalization = ListContinuationService.normalizeOrderedList(
    in: deletedMiddleItem,
    aroundUTF16Location: ("1. 第一项\n" as NSString).length
)
require(
    deletedMiddleNormalization?.text == "1. 第一项\n2. 第三项\n3. 第四项",
    "ordered list renumbers after deleting a middle item"
)

let insertedMiddleItem = """
1. 第一项
2. 新增项
2. 第二项
3. 第三项
"""
let insertedMiddleNormalization = ListContinuationService.normalizeOrderedList(
    in: insertedMiddleItem,
    aroundUTF16Location: ("1. 第一项\n2. 新增项\n" as NSString).length
)
require(
    insertedMiddleNormalization?.text == "1. 第一项\n2. 新增项\n3. 第二项\n4. 第三项",
    "ordered list renumbers after inserting a middle item"
)

let nestedOrderedList = """
1. 第一项
   - 子项
3. 第三项
"""
require(
    ListContinuationService.normalizeOrderedList(
        in: nestedOrderedList,
        aroundUTF16Location: (nestedOrderedList as NSString).length
    )?.text == "1. 第一项\n   - 子项\n2. 第三项",
    "ordered list keeps one sequence across nested content"
)
require(
    ListContinuationService.isManualOrderedMarkerEdit(
        in: "1. 第一项\n2. 第二项",
        range: NSRange(location: ("1. 第一项\n" as NSString).length, length: 1),
        replacement: "8"
    ),
    "manual ordered marker edit is detected"
)

let pastedOrderedList = "4. 第四项\n7. 第七项\n10. 第十项"
require(
    !ListContinuationService.shouldNormalizeOrderedListEdit(
        in: "",
        range: NSRange(location: 0, length: 0),
        replacement: pastedOrderedList
    ),
    "multi-line paste preserves explicit ordered markers"
)
require(
    !ListContinuationService.shouldNormalizeOrderedListEdit(
        in: pastedOrderedList,
        range: NSRange(
            location: (pastedOrderedList as NSString).length,
            length: 0
        ),
        replacement: "\n11. "
    ),
    "Return at document end does not rewrite the pasted list"
)
require(
    ListContinuationService.shouldNormalizeOrderedListEdit(
        in: "1. 第一项\n2. 第二项",
        range: NSRange(location: ("1. 第一项" as NSString).length, length: 0),
        replacement: "\n2. 新增项"
    ),
    "inserting a middle list item still triggers normalization"
)

let untitledDocument = EditorDocument()
require(untitledDocument.isDisposableBlank, "new untitled document is disposable")
untitledDocument.text = "临时内容"
untitledDocument.refreshDirtyState()
require(untitledDocument.isDirty, "typed untitled document is dirty")
require(!untitledDocument.isDisposableBlank, "non-empty untitled document is not disposable")
untitledDocument.text = ""
untitledDocument.refreshDirtyState()
require(!untitledDocument.isDirty, "cleared untitled document returns to clean state")
require(untitledDocument.isDisposableBlank, "cleared untitled document becomes disposable")

let openedDocument = EditorDocument(text: "已保存内容")
openedDocument.url = URL(fileURLWithPath: "/tmp/已保存.txt")
require(!openedDocument.isDisposableBlank, "file-backed document is not disposable")
openedDocument.text = ""
openedDocument.refreshDirtyState()
require(openedDocument.isDirty, "clearing saved file remains dirty")
openedDocument.markSaved()
require(!openedDocument.isDirty, "marking document saved clears dirty state")

require(
    TextSearchService.interpreted(#"第一行\n第二行\t值\s\\尾"#, enabled: true)
        == "第一行\n第二行\t值 \\尾",
    "find escape interpretation"
)
let replaceResult = TextSearchService.replacingAll(
    in: "a b a",
    query: "a",
    replacement: "x",
    caseSensitive: true
)
require(replaceResult.text == "x b x", "replace all output")
require(replaceResult.count == 2, "replace all count")

let headingSource = "# 一级\n正文\n## 二级\n内容\n# 下一个\n"
let headingRange = FoldService.foldableRange(in: headingSource, at: 0, language: .markdown)
require(headingRange == NSRange(location: 5, length: 12), "Markdown fold range")

let jsonSource = #"{"editor":{"wrap":true}}"#
let cursor = (jsonSource as NSString).range(of: #""wrap""#).location
if let jsonRange = FoldService.foldableRange(in: jsonSource, at: cursor, language: .json) {
    require((jsonSource as NSString).substring(with: jsonRange) == #""wrap":true"#, "JSON fold range")
} else {
    fatalError("Verification failed: missing JSON fold range")
}

print("Core verification passed")
