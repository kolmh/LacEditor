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

private func effectiveSyntaxKind(
    _ needle: String,
    in text: String,
    language: EditorLanguage
) -> SyntaxHighlighter.TokenKind? {
    let needleRange = (text as NSString).range(of: needle)
    guard needleRange.location != NSNotFound else {
        fatalError("Verification failed: missing syntax sample \(needle)")
    }
    return SyntaxHighlighter.tokens(in: text, language: language).last {
        NSLocationInRange(needleRange.location, $0.range)
    }?.kind
}

require(
    SyntaxHighlighter.tokens(in: "普通文本", language: .plainText).isEmpty,
    "plain text has no syntax tokens"
)
require(
    effectiveSyntaxKind("**不是强调**", in: "`**不是强调**`", language: .markdown)
        == .string,
    "Markdown inline code protects emphasis markers"
)
require(
    effectiveSyntaxKind("true", in: #"{"enabled":"true","actual":true}"#, language: .json)
        == .string,
    "JSON string protects literal-looking content"
)
require(
    effectiveSyntaxKind(#""enabled""#, in: #"{"enabled":true}"#, language: .json)
        == .property,
    "JSON object key highlighting"
)
require(
    effectiveSyntaxKind("<div>", in: "<!-- <div> --><p class=\"lead\">正文</p>", language: .html)
        == .comment,
    "HTML comments protect embedded tags"
)
require(
    effectiveSyntaxKind("class", in: "<p class=\"lead\">正文</p>", language: .html)
        == .attribute,
    "HTML attribute highlighting"
)

let javascriptSyntax = #"const url = "https://example.com"; // actual comment"#
require(
    effectiveSyntaxKind("//example", in: javascriptSyntax, language: .javascript)
        == .string,
    "JavaScript comment marker inside string stays a string"
)
require(
    effectiveSyntaxKind("// actual", in: javascriptSyntax, language: .javascript)
        == .comment,
    "JavaScript line comment highlighting"
)
for separator in ["\n", "\r\n", "\r", "\u{2028}", "\u{2029}"] {
    let source = "const first = true; // comment\(separator)const next = false;"
    require(
        effectiveSyntaxKind("comment", in: source, language: .javascript) == .comment,
        "JavaScript comment starts before \(separator.debugDescription)"
    )
    require(
        effectiveSyntaxKind("false", in: source, language: .javascript) == .literal,
        "JavaScript comment ends at \(separator.debugDescription)"
    )
}
let unterminatedJavaScriptString = "const value = \"unfinished\nconst next = true;"
require(
    effectiveSyntaxKind("true", in: unterminatedJavaScriptString, language: .javascript)
        == .literal,
    "unterminated JavaScript string stops at the line boundary"
)
require(
    effectiveSyntaxKind("interface", in: "interface Item { value: string }", language: .typescript)
        == .keyword,
    "TypeScript keyword highlighting"
)
require(
    effectiveSyntaxKind("color", in: "/* color: red */\na { color: #fff; }", language: .css)
        == .comment,
    "CSS comments protect property-looking content"
)
require(
    effectiveSyntaxKind("# literal", in: "value = \"# literal\" # actual", language: .python)
        == .string,
    "Python comment marker inside string stays a string"
)
require(
    effectiveSyntaxKind("// literal", in: #"let value = "// literal" // actual"#, language: .swift)
        == .string,
    "Swift comment marker inside string stays a string"
)
require(
    effectiveSyntaxKind("# literal", in: "echo \"# literal\" # actual", language: .shell)
        == .string,
    "Shell comment marker inside string stays a string"
)
require(
    effectiveSyntaxKind("# literal", in: "value: \"# literal\" # actual", language: .yaml)
        == .string,
    "YAML comment marker inside string stays a string"
)
require(
    effectiveSyntaxKind("// literal", in: #"const char *value = "// literal"; // actual"#, language: .cFamily)
        == .string,
    "C-family comment marker inside string stays a string"
)
require(
    effectiveSyntaxKind("-- literal", in: "SELECT '-- literal'; -- actual", language: .sql)
        == .string,
    "SQL comment marker inside string stays a string"
)

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
let initialRevision = untitledDocument.textRevision
untitledDocument.text = "临时内容"
require(
    untitledDocument.textRevision == initialRevision + 1,
    "text revision advances after editing"
)
require(untitledDocument.wordCount == 4, "word count cache updates after editing")
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

let lineIndexSource = "第一行\n第二行"
let lineIndex = LogicalLineIndex(text: lineIndexSource)
let secondLineStart = ("第一行\n" as NSString).length
let initialPosition = lineIndex.position(
    at: secondLineStart,
    in: lineIndexSource as NSString
)
require(initialPosition.line == 2, "logical line index initial line")
require(initialPosition.column == 1, "logical line index initial column")

lineIndex.applyEdit(
    range: NSRange(location: secondLineStart, length: 0),
    replacement: "新增行\n"
)
let insertedLineSource = "第一行\n新增行\n第二行"
let insertedPosition = lineIndex.position(
    at: ("第一行\n新增行\n" as NSString).length,
    in: insertedLineSource as NSString
)
require(insertedPosition.line == 3, "logical line index tracks inserted newline")
require(
    lineIndex.textLength == (insertedLineSource as NSString).length,
    "logical line index tracks inserted text length"
)

let insertedLineRange = (insertedLineSource as NSString).range(of: "新增行\n")
lineIndex.applyEdit(range: insertedLineRange, replacement: "")
let deletedPosition = lineIndex.position(
    at: secondLineStart,
    in: lineIndexSource as NSString
)
require(deletedPosition.line == 2, "logical line index tracks deleted newline")
require(
    lineIndex.textLength == (lineIndexSource as NSString).length,
    "logical line index tracks deleted text length"
)
require(
    lineIndex.lineNumber(at: Int.max) == 2,
    "logical line index clamps locations at text end"
)

let emojiLine = "😀a\n末尾"
let emojiIndex = LogicalLineIndex(text: emojiLine)
let emojiPosition = emojiIndex.position(
    at: ("😀a" as NSString).length,
    in: emojiLine as NSString
)
require(emojiPosition.line == 1, "logical line index keeps emoji on first line")
require(
    emojiPosition.column == 3,
    "logical line index reports character-based Unicode columns"
)

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
