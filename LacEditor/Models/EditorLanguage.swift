import Foundation

enum EditorLanguage: String, CaseIterable, Identifiable {
    case plainText = "Plain Text"
    case markdown = "Markdown"
    case json = "JSON"
    case html = "HTML"
    case javascript = "JavaScript"
    case typescript = "TypeScript"
    case css = "CSS"
    case python = "Python"
    case swift = "Swift"
    case shell = "Shell"
    case yaml = "YAML"
    case cFamily = "C / C++"
    case sql = "SQL"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .plainText: "doc.plaintext"
        case .markdown: "text.document"
        case .json: "curlybraces"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .javascript: "curlybraces.square"
        case .typescript: "t.square"
        case .css: "paintbrush"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .swift: "swift"
        case .shell: "terminal"
        case .yaml: "list.bullet.rectangle"
        case .cFamily: "c.square"
        case .sql: "cylinder.split.1x2"
        }
    }

    static func infer(from url: URL?) -> EditorLanguage {
        guard let ext = url?.pathExtension.lowercased() else { return .plainText }
        switch ext {
        case "md", "markdown": return .markdown
        case "json": return .json
        case "html", "htm": return .html
        case "js", "mjs", "cjs": return .javascript
        case "ts", "tsx": return .typescript
        case "css": return .css
        case "py", "pyw": return .python
        case "swift": return .swift
        case "sh", "bash", "zsh": return .shell
        case "yaml", "yml": return .yaml
        case "c", "h", "cc", "cpp", "cxx", "hpp": return .cFamily
        case "sql": return .sql
        default: return .plainText
        }
    }
}
