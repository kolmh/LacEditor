import Combine
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("Verification failed: \(message)")
    }
}

let selectedLineSource = "first\nsecond wraps here\nthird\n" as NSString
let selectedLineBounds = LogicalLineIndex.selectedLineLocations(
    in: selectedLineSource,
    selectedRange: NSRange(location: 2, length: 23)
)
require(
    selectedLineBounds.contains(0),
    "multi-line selection includes its first line"
)
require(
    selectedLineBounds.contains(6),
    "multi-line selection includes its middle line"
)
require(
    selectedLineBounds.contains(24),
    "multi-line selection includes its last line"
)
require(
    !selectedLineBounds.contains(selectedLineSource.length),
    "multi-line selection excludes an unselected trailing empty line"
)
let wrappedLineRange = selectedLineSource.lineRange(
    for: NSRange(location: 6, length: 0)
)
require(
    LogicalLineIndex.layoutAnchorCharacterIndex(
        in: selectedLineSource,
        lineRange: wrappedLineRange
    ) == wrappedLineRange.location,
    "wrapped line number uses the first visual fragment"
)

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

    let multilineInvalidJSON = "{\n  \"a\": 1,\n  \"b\":\n}"
    do {
        _ = try JSONFormatter.format(multilineInvalidJSON, pretty: true)
        fatalError("Verification failed: multiline invalid JSON was accepted")
    } catch {
        let message = JSONFormatter.userFacingError(error, in: multilineInvalidJSON)
        require(message.contains("第 4 行"), "invalid JSON line number")
        require(message.contains("第 1 列"), "invalid JSON column number")
    }
} catch {
    fatalError("Verification failed: JSON formatter threw \(error)")
}

do {
    let urlSource = "你好 world?name=LacEditor&enabled=true"
    let urlEncoded = try TextCodecService.transform(
        urlSource,
        operation: .urlEncodeComponent
    )
    require(
        urlEncoded == "%E4%BD%A0%E5%A5%BD%20world%3Fname%3DLacEditor%26enabled%3Dtrue",
        "URL component encoding uses UTF-8 and preserves only unreserved characters"
    )
    let urlDecoded = try TextCodecService.transform(urlEncoded, operation: .urlDecode)
    require(urlDecoded == urlSource, "URL component round trip")
    let standardPlusDecoded = try TextCodecService.transform(
        "a+b%20c",
        operation: .urlDecode
    )
    require(
        standardPlusDecoded == "a+b c",
        "standard URL decoding preserves plus"
    )
    let formPlusDecoded = try TextCodecService.transform(
        "a+b%20c",
        operation: .formURLDecode
    )
    require(
        formPlusDecoded == "a b c",
        "form URL decoding maps plus to space"
    )

    let base64 = try TextCodecService.transform("LacEditor 中文", operation: .base64Encode)
    let base64Decoded = try TextCodecService.transform(base64, operation: .base64Decode)
    require(base64Decoded == "LacEditor 中文", "Base64 UTF-8 round trip")
    let base64URL = try TextCodecService.transform("路径?/+", operation: .base64URLEncode)
    require(!base64URL.contains("="), "Base64URL omits padding")
    let base64URLDecoded = try TextCodecService.transform(
        base64URL,
        operation: .base64URLDecode
    )
    require(base64URLDecoded == "路径?/+", "Base64URL UTF-8 round trip")

    let htmlSource = #"<a title="Lac & Editor">©</a>"#
    let htmlEncoded = try TextCodecService.transform(htmlSource, operation: .htmlEncode)
    require(
        htmlEncoded == "&lt;a title=&quot;Lac &amp; Editor&quot;&gt;©&lt;/a&gt;",
        "HTML entity encoding"
    )
    let htmlDecoded = try TextCodecService.transform(htmlEncoded, operation: .htmlDecode)
    require(htmlDecoded == htmlSource, "HTML entity round trip")
    let numericEntities = try TextCodecService.transform(
        "&#x4F60;&#22909; &copy;",
        operation: .htmlDecode
    )
    require(
        numericEntities == "你好 ©",
        "numeric and common named HTML entities"
    )

    let unicodeSource = "你好 😀\n\t\"\\"
    let unicodeEncoded = try TextCodecService.transform(
        unicodeSource,
        operation: .unicodeEncode
    )
    require(unicodeEncoded.contains(#"\u4F60\u597D"#), "Unicode BMP escaping")
    require(unicodeEncoded.contains(#"\uD83D\uDE00"#), "Unicode surrogate escaping")
    let unicodeDecoded = try TextCodecService.transform(
        unicodeEncoded,
        operation: .unicodeDecode
    )
    require(unicodeDecoded == unicodeSource, "Unicode and JSON escape round trip")
    let bracedUnicode = try TextCodecService.transform(
        #"\u{1F600}"#,
        operation: .unicodeDecode
    )
    require(bracedUnicode == "😀", "braced Unicode escape")

    require(
        TextCodecService.detect(in: "hello%20world")?.kind == .url,
        "smart URL detection"
    )
    require(
        TextCodecService.detect(in: "SGVsbG8gTGFjRWRpdG9y")?.kind == .base64,
        "smart Base64 detection"
    )
    require(
        TextCodecService.detect(
            in: "SGVsbG8gTGFjRWRpdG9y",
            allowsBase64: false
        ) == nil,
        "Base64 is only suggested for an explicit selection"
    )
    require(
        TextCodecService.detect(in: #"\u4F60\u597D"#)?.kind == .unicodeEscape,
        "smart Unicode detection"
    )
    require(
        TextCodecService.detect(in: "ordinaryText") == nil,
        "ordinary text is not misdetected"
    )

    let candidateSource = "prefix hello%20world suffix" as NSString
    let candidateLocation = candidateSource.range(of: "%20").location
    let candidate = TextCodecService.candidate(
        in: candidateSource,
        selection: NSRange(location: candidateLocation, length: 0),
        allowsTokenAtCaret: true,
        maximumLength: TextCodecService.automaticDetectionLimit
    )
    require(candidate?.text == "hello%20world", "caret token extraction")
    let oversizedToken = NSString(
        string: String(
            repeating: "A",
            count: TextCodecService.automaticDetectionLimit + 1
        )
    )
    require(
        TextCodecService.candidate(
            in: oversizedToken,
            selection: NSRange(location: oversizedToken.length / 2, length: 0),
            allowsTokenAtCaret: true,
            maximumLength: TextCodecService.automaticDetectionLimit
        ) == nil,
        "automatic detection rejects oversized tokens without scanning beyond its limit"
    )

    do {
        _ = try TextCodecService.transform("broken%2", operation: .urlDecode)
        fatalError("Verification failed: invalid URL encoding was accepted")
    } catch let error as TextCodecError {
        require(error == .invalidPercentEncoding, "invalid URL encoding error")
    }
    do {
        _ = try TextCodecService.transform("/w==", operation: .base64Decode)
        fatalError("Verification failed: binary Base64 was accepted as text")
    } catch let error as TextCodecError {
        require(error == .nonTextBase64, "binary Base64 text guard")
    }
    do {
        _ = try TextCodecService.transform(#"\uD83D"#, operation: .unicodeDecode)
        fatalError("Verification failed: unmatched surrogate was accepted")
    } catch {
        require(true, "unmatched Unicode surrogate rejected")
    }
} catch {
    fatalError("Verification failed: text codec threw \(error)")
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

let inlineCodeHTML = MarkdownRenderer.render(
    #"`**保持原样** [链接](https://example.com)`"#,
    darkMode: false
)
require(
    inlineCodeHTML.contains(
        #"<code>**保持原样** [链接](https://example.com)</code>"#
    ),
    "Markdown inline code protects nested markup"
)
require(
    !inlineCodeHTML.contains("<code><strong>"),
    "Markdown inline code is not emphasized"
)
let inlineCodeCollisionHTML = MarkdownRenderer.render(
    "LACXINCODEX0XENDLAC and `code`",
    darkMode: false
)
require(
    inlineCodeCollisionHTML.contains("LACXINCODEX0XENDLAC and <code>code</code>"),
    "Markdown inline code placeholder cannot collide with source text"
)
let underscoredLinkHTML = MarkdownRenderer.render(
    "[链接](https://example.com/foo_bar_baz)",
    darkMode: false
)
require(
    underscoredLinkHTML.contains(
        #"<a href="https://example.com/foo_bar_baz">链接</a>"#
    ),
    "Markdown emphasis does not alter link destinations"
)
require(
    !underscoredLinkHTML.contains("<em>"),
    "Markdown link destination underscores stay literal"
)
let crlfMarkdownHTML = MarkdownRenderer.render(
    "第一行\r\n第二行",
    darkMode: false
)
require(
    crlfMarkdownHTML.contains("<p>第一行 第二行</p>"),
    "Markdown treats CRLF as one line separator"
)

let orderedMarkdown = """
1. 第一项
2. 第二项
   - 子项 A
   - 子项 B
3. 第三项
4. 第四项
5. 第五项
"""
let veryLongOrderedList = (1...501)
    .map { "\($0). item \($0)" }
    .joined(separator: "\n") as NSString
require(
    ListContinuationService.orderedListExceedsBackgroundThreshold(
        in: veryLongOrderedList,
        aroundUTF16Location: veryLongOrderedList.length / 2
    ),
    "ordered lists over 500 items use background normalization"
)
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

private func delimiterMatch(
    in text: String,
    at location: Int,
    length: Int = 0,
    language: EditorLanguage,
    revision: UInt = 1,
    context: DelimiterMatchingService.Context = .init()
) -> DelimiterMatchingService.Match? {
    DelimiterMatchingService.match(
        in: text,
        selection: NSRange(location: location, length: length),
        language: language,
        revision: revision,
        context: context
    )
}

let nestedDelimiters = "函数() { let values = [中文, (1 + 2)] }" as NSString
let outerOpening = nestedDelimiters.range(of: "{").location
let outerClosing = nestedDelimiters.range(of: "}").location
let outerMatch = delimiterMatch(
    in: nestedDelimiters as String,
    at: outerOpening,
    language: .javascript
)
require(outerMatch?.openingRange.location == outerOpening, "opening brace match")
require(outerMatch?.closingRange.location == outerClosing, "nested closing brace match")
require(
    delimiterMatch(
        in: nestedDelimiters as String,
        at: outerOpening + 1,
        language: .javascript
    ) == outerMatch,
    "caret after opening brace match"
)

let closingCaretMatch = delimiterMatch(
    in: nestedDelimiters as String,
    at: outerClosing + 1,
    language: .javascript
)
require(closingCaretMatch == outerMatch, "caret after closing brace match")

let selectedBracket = nestedDelimiters.range(of: "[")
require(
    delimiterMatch(
        in: nestedDelimiters as String,
        at: selectedBracket.location,
        length: 1,
        language: .javascript
    )?.openingRange == selectedBracket,
    "single selected bracket match"
)
require(
    delimiterMatch(
        in: nestedDelimiters as String,
        at: outerOpening,
        length: 2,
        language: .javascript
    ) == nil,
    "multi-character selection does not match"
)

let protectedJavaScript = #"""
let a = "fake { }"; // fake [ ]
let b = `template ( )`;
let r = /[{}()]/;
/* fake { [ ( ) ] } */
function run() { return [1, 2]; }
"""# as NSString
for marker in ["fake {", "fake [", "template (", "[{}()", "/* fake {"] {
    let protectedLocation = protectedJavaScript.range(of: marker).location
        + (marker as NSString).length - 1
    require(
        delimiterMatch(
            in: protectedJavaScript as String,
            at: protectedLocation,
            language: .javascript
        ) == nil,
        "delimiter inside protected JavaScript token is ignored: \(marker)"
    )
}
let functionOpening = protectedJavaScript.range(
    of: "{",
    options: [],
    range: NSRange(
        location: protectedJavaScript.range(of: "function run").location,
        length: protectedJavaScript.length
            - protectedJavaScript.range(of: "function run").location
    )
).location
require(
    delimiterMatch(
        in: protectedJavaScript as String,
        at: functionOpening,
        language: .javascript
    ) != nil,
    "real JavaScript block still matches"
)

require(
    delimiterMatch(in: "([)]", at: 0, language: .javascript) == nil,
    "crossed delimiters do not produce a false pair"
)
require(
    delimiterMatch(in: "{ missing", at: 0, language: .json) == nil,
    "unclosed delimiter stays silent"
)
require(
    delimiterMatch(in: "[link](url)", at: 0, language: .markdown) == nil,
    "Markdown is outside delimiter matching scope"
)
let delimiterLanguages: [EditorLanguage] = [
    .json, .javascript, .typescript, .css, .python, .swift,
    .shell, .yaml, .cFamily, .sql
]
for language in delimiterLanguages {
    require(
        delimiterMatch(in: "{[()]}", at: 0, language: language) != nil,
        "delimiter matching is enabled for \(language.rawValue)"
    )
}
for language in [EditorLanguage.plainText, .markdown, .html] {
    require(
        !DelimiterMatchingService.supports(language),
        "delimiter matching stays disabled for \(language.rawValue)"
    )
}

let longComment = "{ // " + String(repeating: "x", count: 70_000) + " }\n}"
require(
    delimiterMatch(in: longComment, at: 0, language: .javascript)?.closingRange.location
        == (longComment as NSString).length - 1,
    "line comments remain protected across lexical chunks"
)
let longRegex = "let r = /" + String(repeating: "x", count: 70_000)
    + "{}/;\nfunction run() {}"
let fakeRegexBrace = (longRegex as NSString).range(of: "{").location
require(
    delimiterMatch(in: longRegex, at: fakeRegexBrace, language: .javascript) == nil,
    "JavaScript regex remains protected across lexical chunks"
)

let changingContext = DelimiterMatchingService.Context()
require(
    delimiterMatch(
        in: "{[]}",
        at: 0,
        language: .json,
        revision: 1,
        context: changingContext
    ) != nil,
    "initial revision matches"
)
changingContext.invalidate(after: 1)
require(
    delimiterMatch(
        in: "{[()]}",
        at: 0,
        language: .json,
        revision: 2,
        context: changingContext
    )?.closingRange.location == 5,
    "edited revision rebuilds invalidated delimiter checkpoints"
)

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
let javascriptRegexSyntax = #"""
const csvEscape = (val) => {
  const s = String(val);
  if (/[",\n\r]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
  return s;
};

const cleanText = (text) => {
  let t = String(text);
};
"""#
require(
    effectiveSyntaxKind(#"/[",\n\r]/"#, in: javascriptRegexSyntax, language: .javascript)
        == .string,
    "JavaScript regex character class protects embedded quotes"
)
require(
    effectiveSyntaxKind(#"/"/g"#, in: javascriptRegexSyntax, language: .javascript)
        == .string,
    "JavaScript regex literal inside a function call"
)
require(
    effectiveSyntaxKind("return s;", in: javascriptRegexSyntax, language: .javascript)
        == .keyword,
    "JavaScript highlighting resumes after a regex literal"
)
require(
    effectiveSyntaxKind("let t", in: javascriptRegexSyntax, language: .javascript)
        == .keyword,
    "JavaScript highlighting remains correct in the following function"
)
let escapedSlashRegex = #"const protocol = /https?:\/\//; // URL scheme"#
require(
    effectiveSyntaxKind(#"/https?:\/\//"#, in: escapedSlashRegex, language: .javascript)
        == .string,
    "escaped slashes inside a JavaScript regex are not comments"
)
require(
    effectiveSyntaxKind("// URL", in: escapedSlashRegex, language: .javascript)
        == .comment,
    "JavaScript comments still begin after a regex literal"
)
let javascriptDivision = "const ratio = total / count;"
require(
    effectiveSyntaxKind("/", in: javascriptDivision, language: .javascript) == nil,
    "JavaScript division is not classified as a regex or comment"
)

let incrementalCommentBody = String(repeating: "comment payload\n", count: 6_000)
let incrementalCommentSource = "/*\n\(incrementalCommentBody)deep_marker\n*/\nconst after = true;"
let incrementalCommentContext = SyntaxHighlighter.IncrementalContext()
let incrementalMarkerRange = (incrementalCommentSource as NSString).range(
    of: "deep_marker"
)
let incrementalMarkerTokens = SyntaxHighlighter.tokens(
    in: incrementalCommentSource,
    language: .javascript,
    range: incrementalMarkerRange,
    context: incrementalCommentContext,
    revision: 0
)
require(
    incrementalMarkerTokens.last {
        NSLocationInRange(incrementalMarkerRange.location, $0.range)
    }?.kind == .comment,
    "incremental highlighting carries block-comment state beyond 64 KiB"
)
let incrementalAfterRange = (incrementalCommentSource as NSString).range(
    of: "const after"
)
let incrementalAfterTokens = SyntaxHighlighter.tokens(
    in: incrementalCommentSource,
    language: .javascript,
    range: incrementalAfterRange,
    context: incrementalCommentContext,
    revision: 0
)
require(
    incrementalAfterTokens.last {
        NSLocationInRange(incrementalAfterRange.location, $0.range)
    }?.kind == .keyword,
    "incremental highlighting exits a long block comment"
)

let closeRange = (incrementalCommentSource as NSString).range(of: "*/")
let unclosedIncrementalSource = (incrementalCommentSource as NSString)
    .replacingCharacters(in: closeRange, with: "  ")
incrementalCommentContext.invalidate(after: closeRange.location)
let invalidatedTokens = SyntaxHighlighter.tokens(
    in: unclosedIncrementalSource,
    language: .javascript,
    range: incrementalAfterRange,
    context: incrementalCommentContext,
    revision: 1
)
require(
    invalidatedTokens.last {
        NSLocationInRange(incrementalAfterRange.location, $0.range)
    }?.kind == .comment,
    "editing a closing delimiter invalidates following lexical checkpoints"
)

let templateBody = String(repeating: "template payload\n", count: 5_000)
let templateSource = "const text = `\(templateBody)template_marker`;\nconst done = true;"
let templateContext = SyntaxHighlighter.IncrementalContext()
let templateMarkerRange = (templateSource as NSString).range(of: "template_marker")
let templateTokens = SyntaxHighlighter.tokens(
    in: templateSource,
    language: .javascript,
    range: templateMarkerRange,
    context: templateContext,
    revision: 0
)
require(
    templateTokens.last {
        NSLocationInRange(templateMarkerRange.location, $0.range)
    }?.kind == .string,
    "incremental highlighting carries multiline-string state beyond 64 KiB"
)

let checkpointScanEnd = 1 + (16 * 1_024)
let continuedStringPrefix = "const value = \""
let continuedStringPadding = String(
    repeating: "x",
    count: checkpointScanEnd - (continuedStringPrefix as NSString).length - 2
)
let continuedStringSource = continuedStringPrefix
    + continuedStringPadding
    + "\\\r\ncontinued_marker\";"
let continuedStringContext = SyntaxHighlighter.IncrementalContext()
_ = SyntaxHighlighter.tokens(
    in: continuedStringSource,
    language: .javascript,
    range: NSRange(location: 0, length: 1),
    context: continuedStringContext,
    revision: 0
)
let continuedStringMarkerRange = (continuedStringSource as NSString).range(
    of: "continued_marker"
)
let continuedStringTokens = SyntaxHighlighter.tokens(
    in: continuedStringSource,
    language: .javascript,
    range: continuedStringMarkerRange,
    context: continuedStringContext,
    revision: 0
)
require(
    continuedStringTokens.last {
        NSLocationInRange(continuedStringMarkerRange.location, $0.range)
    }?.kind == .string,
    "incremental checkpoint never splits an escaped CRLF continuation"
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

let liveDocument = EditorDocument(
    text: "已保存内容",
    url: URL(fileURLWithPath: "/tmp/live-sync.txt")
)
var liveText = "已保存内容 + 编辑"
var acknowledgedRevision: UInt?
let liveProviderID = UUID()
liveDocument.attachLiveTextProvider(
    id: liveProviderID,
    provider: { liveText },
    acknowledgement: { acknowledgedRevision = $0 }
)
liveDocument.noteLiveEdit(isEmpty: false)
require(
    liveDocument.text == "已保存内容",
    "live editing defers the full model snapshot"
)
require(liveDocument.isDirty, "live editing marks the document dirty immediately")
require(liveDocument.hasPendingLiveEdits, "live editing records a pending snapshot")
require(liveDocument.synchronizeLiveText(), "pending live text synchronizes on demand")
require(liveDocument.text == liveText, "live text synchronization uses the current editor text")
require(
    acknowledgedRevision == liveDocument.textRevision,
    "the active editor acknowledges its synchronized model revision"
)

liveText = "已保存内容"
liveDocument.noteLiveEdit(isEmpty: false)
liveDocument.refreshDirtyState()
require(!liveDocument.isDirty, "idle reconciliation detects undo back to the saved text")
liveDocument.detachLiveTextProvider(id: liveProviderID)

let reentrantDocument = EditorDocument(text: "已保存")
var dirtyStateNotificationCount = 0
let dirtyStateCancellable = reentrantDocument.$isDirty
    .dropFirst()
    .sink { _ in
        dirtyStateNotificationCount += 1
        reentrantDocument.refreshDirtyState()
    }
reentrantDocument.text = "已修改"
reentrantDocument.refreshDirtyState()
require(reentrantDocument.isDirty, "reentrant dirty-state refresh keeps the correct result")
require(
    dirtyStateNotificationCount == 1,
    "reentrant dirty-state refresh does not publish recursively"
)
dirtyStateCancellable.cancel()

let liveUntitledDocument = EditorDocument()
var liveUntitledText = "草稿"
let liveUntitledProviderID = UUID()
liveUntitledDocument.attachLiveTextProvider(
    id: liveUntitledProviderID,
    provider: { liveUntitledText },
    acknowledgement: { _ in }
)
liveUntitledDocument.noteLiveEdit(isEmpty: false)
require(
    !liveUntitledDocument.isDisposableBlank,
    "pending non-empty untitled text is not disposable"
)
liveUntitledText = ""
liveUntitledDocument.noteLiveEdit(isEmpty: true)
require(
    liveUntitledDocument.isDisposableBlank,
    "pending empty untitled text remains disposable without a full snapshot"
)
liveUntitledDocument.detachLiveTextProvider(id: liveUntitledProviderID)

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
    replacement: "新增行\n",
    in: lineIndexSource as NSString
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
lineIndex.applyEdit(
    range: insertedLineRange,
    replacement: "",
    in: insertedLineSource as NSString
)
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

for separator in ["\r", "\r\n", "\u{2028}", "\u{2029}"] {
    let source = "第一行\(separator)第二行"
    let index = LogicalLineIndex(text: source)
    let secondLineLocation = ("第一行\(separator)" as NSString).length
    let position = index.position(
        at: secondLineLocation,
        in: source as NSString
    )
    require(position.line == 2, "logical line index handles \(separator.debugDescription)")
    require(position.column == 1, "logical line column handles \(separator.debugDescription)")
}

let crlfSource = "第一行\r\n第二行"
let crlfIndex = LogicalLineIndex(text: crlfSource)
let lfLocation = ("第一行\r" as NSString).length
crlfIndex.applyEdit(
    range: NSRange(location: lfLocation, length: 1),
    replacement: "",
    in: crlfSource as NSString
)
let crSource = "第一行\r第二行"
require(
    crlfIndex.position(
        at: ("第一行\r" as NSString).length,
        in: crSource as NSString
    ).line == 2,
    "logical line index rescans a changed CRLF boundary"
)

let legacyDocument = EditorDocument(text: "一\r二\r\n三\u{2028}四\u{2029}五")
require(legacyDocument.lineCount == 5, "document counts all supported line separators")

let renamedDocument = EditorDocument(
    url: URL(fileURLWithPath: "/tmp/example.txt"),
    language: .plainText
)
var renamedDocumentSnapshots: [String] = []
let renamedDocumentObservation = renamedDocument.objectWillChange.sink {
    renamedDocumentSnapshots.append(renamedDocument.displayName)
}
renamedDocument.updateLocationAfterRename(
    from: URL(fileURLWithPath: "/tmp/other.txt"),
    to: URL(fileURLWithPath: "/tmp/example.md")
)
require(
    renamedDocument.url?.lastPathComponent == "example.txt",
    "rename ignores unrelated document"
)
renamedDocument.updateLocationAfterRename(
    from: URL(fileURLWithPath: "/tmp/example.txt"),
    to: URL(fileURLWithPath: "/tmp/example.md")
)
require(renamedDocument.url?.lastPathComponent == "example.md", "rename updates URL")
require(renamedDocument.language == .markdown, "rename updates inferred language")
require(renamedDocument.isPreviewVisible, "rename enables Markdown preview")
require(
    renamedDocumentSnapshots.last == "example.md",
    "rename publishes one consistent post-update title"
)
renamedDocument.updateLocationAfterRename(
    from: URL(fileURLWithPath: "/tmp/example.md"),
    to: URL(fileURLWithPath: "/tmp/example.js")
)
require(renamedDocument.language == .javascript, "second rename updates language")
require(!renamedDocument.isPreviewVisible, "rename hides preview outside Markdown")

let savedAsDocument = EditorDocument()
savedAsDocument.updateLocation(to: URL(fileURLWithPath: "/tmp/saved-as.md"))
require(savedAsDocument.language == .markdown, "save as updates inferred language")
require(savedAsDocument.isPreviewVisible, "save as enables Markdown preview")
savedAsDocument.isPreviewVisible = false
savedAsDocument.updateLocation(to: URL(fileURLWithPath: "/tmp/saved-again.md"))
require(!savedAsDocument.isPreviewVisible, "save as Markdown preserves preview choice")
savedAsDocument.updateLocation(to: URL(fileURLWithPath: "/tmp/saved-as.txt"))
require(!savedAsDocument.isPreviewVisible, "save as hides preview outside Markdown")

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

let siblingJSONSource = #"{"closed":{"value":1},"active":{"value":2}}"#
let activeCursor = (siblingJSONSource as NSString).range(of: #""active""#).location
if let activeRange = FoldService.foldableRange(
    in: siblingJSONSource,
    at: activeCursor,
    language: .json
) {
    require(
        (siblingJSONSource as NSString).substring(with: activeRange)
            == #""closed":{"value":1},"active":{"value":2}"#,
        "JSON fold ignores an already closed sibling container"
    )
} else {
    fatalError("Verification failed: missing JSON sibling fold range")
}

print("Core verification passed")
