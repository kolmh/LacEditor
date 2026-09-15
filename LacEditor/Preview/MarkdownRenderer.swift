import Foundation
import cmark_gfm
import cmark_gfm_extensions

enum MarkdownRenderer {
    private static let extensions = [
        "table",
        "strikethrough",
        "tasklist",
        "autolink",
        "tagfilter"
    ]

    static func render(_ markdown: String, darkMode: Bool) -> String {
        let body = renderBody(markdown)
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
          li > p { margin: .35em 0; }
          blockquote { margin: 1em 0; padding: .15em 1em; color: \(secondary); border-left: 3px solid \(border); }
          hr { border: 0; border-top: 1px solid \(border); margin: 1.8em 0; }
          a { color: \(accent); text-decoration: none; }
          code { font: .9em ui-monospace, SFMono-Regular, Menlo, monospace; background: \(codeBackground); padding: .12em .32em; border-radius: 3px; }
          pre { overflow: auto; background: \(codeBackground); border: 1px solid \(border); padding: 14px 16px; border-radius: 5px; }
          pre code { background: none; padding: 0; }
          table { width: 100%; border-collapse: collapse; margin: 1.2em 0; }
          th, td { border: 1px solid \(border); padding: .48em .7em; text-align: left; }
          th { font-weight: 600; background: \(codeBackground); }
          input[type="checkbox"] { margin: 0 .4em 0 0; accent-color: \(accent); }
          del { color: \(secondary); }
        </style>
        </head>
        <body><article>\(body)</article></body>
        </html>
        """
    }

    private static func renderBody(_ markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()
        // Treat ordinary single newlines as visible line breaks in the preview.
        // This keeps blank-line paragraph separation intact while preventing
        // prose pasted from the editor from appearing as one wrapped line.
        let options = CMARK_OPT_SMART | CMARK_OPT_TABLE_SPANS | CMARK_OPT_HARDBREAKS
        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }

        for name in extensions {
            name.withCString { extensionName in
                guard let syntaxExtension = cmark_find_syntax_extension(extensionName) else {
                    return
                }
                cmark_parser_attach_syntax_extension(parser, syntaxExtension)
            }
        }

        markdown.withCString { source in
            cmark_parser_feed(parser, source, markdown.utf8.count)
        }
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }

        let syntaxExtensions = cmark_parser_get_syntax_extensions(parser)
        guard let rendered = cmark_render_html(document, options, syntaxExtensions) else {
            return ""
        }
        defer { free(rendered) }
        return String(cString: rendered)
    }
}
