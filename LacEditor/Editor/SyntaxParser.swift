import Foundation

#if canImport(SwiftTreeSitter) && canImport(TreeSitterJavaScript) && canImport(TreeSitterTypeScript) && canImport(TreeSitterPython) && canImport(TreeSitterCSS) && canImport(TreeSitterHTML) && canImport(TreeSitterSwift) && canImport(TreeSitterBash) && canImport(TreeSitterYAML) && canImport(TreeSitterC) && canImport(TreeSitterCPP) && canImport(TreeSitterSQL)
import SwiftTreeSitter
import TreeSitterJavaScript
import TreeSitterTypeScript
import TreeSitterPython
import TreeSitterCSS
import TreeSitterHTML
import TreeSitterSwift
import TreeSitterBash
import TreeSitterYAML
import TreeSitterC
import TreeSitterCPP
import TreeSitterSQL
#endif

/// A replaceable syntax parsing boundary. Implementations must return UTF-16
/// ranges and may be called on a background operation, so they must not touch
/// AppKit objects or shared mutable state outside their context.
protocol SyntaxParserBackend {
    func tokens(
        in string: String,
        language: EditorLanguage,
        range: NSRange,
        context: SyntaxHighlighter.IncrementalContext?,
        revision: UInt?,
        documentID: UUID?,
        edit: DocumentEditDelta?,
        isCancelled: @escaping () -> Bool
    ) -> [SyntaxHighlighter.Token]
}

struct LexicalSyntaxParserBackend: SyntaxParserBackend {
    func tokens(
        in string: String,
        language: EditorLanguage,
        range: NSRange,
        context: SyntaxHighlighter.IncrementalContext?,
        revision: UInt?,
        documentID: UUID?,
        edit: DocumentEditDelta?,
        isCancelled: @escaping () -> Bool
    ) -> [SyntaxHighlighter.Token] {
        SyntaxHighlighter.lexicalTokens(
            in: string,
            language: language,
            range: range,
            context: context,
            revision: revision,
            isCancelled: isCancelled
        )
    }
}

#if canImport(SwiftTreeSitter) && canImport(TreeSitterJavaScript) && canImport(TreeSitterTypeScript) && canImport(TreeSitterPython) && canImport(TreeSitterCSS) && canImport(TreeSitterHTML) && canImport(TreeSitterSwift) && canImport(TreeSitterBash) && canImport(TreeSitterYAML) && canImport(TreeSitterC) && canImport(TreeSitterCPP) && canImport(TreeSitterSQL)
/// Tree-sitter backend used for JavaScript documents. Larger documents continue
/// using the existing scanner because keeping the editor responsive is more
/// important than building a full syntax tree for them.
struct TreeSitterJavaScriptBackend: SyntaxParserBackend {
    static let maximumUTF8Bytes = 20 * 1_024 * 1_024

    static func invalidate(documentID: UUID) {
        TreeSitterCodeCache.shared.remove(documentID: documentID)
    }

    func tokens(
        in string: String,
        language: EditorLanguage,
        range: NSRange,
        context _: SyntaxHighlighter.IncrementalContext?,
        revision: UInt?,
        documentID: UUID?,
        edit: DocumentEditDelta?,
        isCancelled: @escaping () -> Bool
    ) -> [SyntaxHighlighter.Token] {
        guard language == .javascript,
              string.utf8.count <= Self.maximumUTF8Bytes,
              !isCancelled() else { return [] }
        let parsed: (Parser, MutableTree)?
        if let documentID {
            parsed = TreeSitterCodeCache.shared.parse(
                string: string,
                revision: revision,
                documentID: documentID,
                edit: edit,
                language: Language(language: tree_sitter_javascript()),
                namespace: "javascript",
                isCancelled: isCancelled
            )
        } else {
            let parser = Parser()
            do {
                try parser.setLanguage(Language(language: tree_sitter_javascript()))
            } catch {
                return []
            }
            parsed = parser.parse(string).map { (parser, $0) }
        }
        guard let (_, tree) = parsed,
              let root = tree.rootNode,
              !isCancelled() else { return [] }
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        let requested = NSIntersectionRange(range, fullRange)
        var result: [SyntaxHighlighter.Token] = []

        func visit(_ node: Node) {
            if isCancelled() { return }
            if let nodeType = node.nodeType,
               let kind = tokenKind(for: nodeType) {
                let nodeRange = UTF16TreeRange.range(
                    for: node.byteRange,
                    stringLength: fullRange.length
                )
                let clipped = NSIntersectionRange(nodeRange, requested)
                if clipped.length > 0 {
                    result.append(.init(range: clipped, kind: kind))
                }
            }
            for index in 0..<node.childCount {
                guard let child = node.child(at: index) else { continue }
                visit(child)
            }
        }
        visit(root)
        return result
    }

    private func tokenKind(
        for nodeType: String
    ) -> SyntaxHighlighter.TokenKind? {
        switch nodeType {
        case "comment": return .comment
        case "string", "template_string", "regex": return .string
        case "number": return .number
        case "true", "false", "null", "undefined": return .literal
        case "property_identifier": return .property
        case "identifier": return .variable
        default: return nil
        }
    }
}

struct TreeSitterTypeScriptBackend: SyntaxParserBackend {
    static let maximumUTF8Bytes = TreeSitterJavaScriptBackend.maximumUTF8Bytes

    func tokens(
        in string: String,
        language: EditorLanguage,
        range: NSRange,
        context _: SyntaxHighlighter.IncrementalContext?,
        revision: UInt?,
        documentID: UUID?,
        edit: DocumentEditDelta?,
        isCancelled: @escaping () -> Bool
    ) -> [SyntaxHighlighter.Token] {
        guard language == .typescript,
              string.utf8.count <= Self.maximumUTF8Bytes,
              !isCancelled() else { return [] }
        let grammar = Language(language: tree_sitter_typescript())
        let parsed: (Parser, MutableTree)?
        if let documentID {
            parsed = TreeSitterCodeCache.shared.parse(
                string: string,
                revision: revision,
                documentID: documentID,
                edit: edit,
                language: grammar,
                namespace: "typescript",
                isCancelled: isCancelled
            )
        } else {
            let parser = Parser()
            do { try parser.setLanguage(grammar) } catch { return [] }
            parsed = parser.parse(string).map { (parser, $0) }
        }
        guard let (_, tree) = parsed,
              let root = tree.rootNode,
              !isCancelled() else { return [] }

        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        let requested = NSIntersectionRange(range, fullRange)
        var result: [SyntaxHighlighter.Token] = []
        func visit(_ node: Node) {
            if isCancelled() { return }
            if let nodeType = node.nodeType,
               let kind = Self.tokenKind(for: nodeType) {
                let nodeRange = UTF16TreeRange.range(
                    for: node.byteRange,
                    stringLength: fullRange.length
                )
                let clipped = NSIntersectionRange(nodeRange, requested)
                if clipped.length > 0 {
                    result.append(.init(range: clipped, kind: kind))
                }
            }
            for index in 0..<node.childCount {
                guard let child = node.child(at: index) else { continue }
                visit(child)
            }
        }
        visit(root)
        return result
    }

    private static func tokenKind(
        for nodeType: String
    ) -> SyntaxHighlighter.TokenKind? {
        switch nodeType {
        case "comment": return .comment
        case "string", "template_string", "regex": return .string
        case "number": return .number
        case "true", "false", "null", "undefined": return .literal
        case "property_identifier": return .property
        case "identifier", "type_identifier", "shorthand_property_identifier_pattern":
            return .variable
        case "type_annotation", "predefined_type", "type_arguments": return .typeName
        default: return nil
        }
    }
}

struct TreeSitterPythonBackend: SyntaxParserBackend {
    static let maximumUTF8Bytes = TreeSitterJavaScriptBackend.maximumUTF8Bytes

    func tokens(
        in string: String,
        language: EditorLanguage,
        range: NSRange,
        context _: SyntaxHighlighter.IncrementalContext?,
        revision: UInt?,
        documentID: UUID?,
        edit: DocumentEditDelta?,
        isCancelled: @escaping () -> Bool
    ) -> [SyntaxHighlighter.Token] {
        guard language == .python,
              string.utf8.count <= Self.maximumUTF8Bytes,
              !isCancelled() else { return [] }
        let grammar = Language(language: tree_sitter_python())
        let parsed: (Parser, MutableTree)?
        if let documentID {
            parsed = TreeSitterCodeCache.shared.parse(
                string: string,
                revision: revision,
                documentID: documentID,
                edit: edit,
                language: grammar,
                namespace: "python",
                isCancelled: isCancelled
            )
        } else {
            let parser = Parser()
            do { try parser.setLanguage(grammar) } catch { return [] }
            parsed = parser.parse(string).map { (parser, $0) }
        }
        guard let (_, tree) = parsed,
              let root = tree.rootNode,
              !isCancelled() else { return [] }

        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        let requested = NSIntersectionRange(range, fullRange)
        var result: [SyntaxHighlighter.Token] = []
        func visit(_ node: Node) {
            if isCancelled() { return }
            if let nodeType = node.nodeType,
               let kind = Self.tokenKind(for: nodeType) {
                let nodeRange = UTF16TreeRange.range(
                    for: node.byteRange,
                    stringLength: fullRange.length
                )
                let clipped = NSIntersectionRange(nodeRange, requested)
                if clipped.length > 0 {
                    result.append(.init(range: clipped, kind: kind))
                }
            }
            for index in 0..<node.childCount {
                guard let child = node.child(at: index) else { continue }
                visit(child)
            }
        }
        visit(root)
        return result
    }

    private static func tokenKind(
        for nodeType: String
    ) -> SyntaxHighlighter.TokenKind? {
        switch nodeType {
        case "comment": return .comment
        case "string", "concatenated_string": return .string
        case "integer", "float": return .number
        case "true", "false", "none": return .literal
        case "identifier": return .variable
        case "type": return .typeName
        default: return nil
        }
    }
}

struct TreeSitterCSSBackend: SyntaxParserBackend {
    static let maximumUTF8Bytes = TreeSitterJavaScriptBackend.maximumUTF8Bytes

    func tokens(
        in string: String,
        language: EditorLanguage,
        range: NSRange,
        context _: SyntaxHighlighter.IncrementalContext?,
        revision: UInt?,
        documentID: UUID?,
        edit: DocumentEditDelta?,
        isCancelled: @escaping () -> Bool
    ) -> [SyntaxHighlighter.Token] {
        guard language == .css,
              string.utf8.count <= Self.maximumUTF8Bytes,
              !isCancelled() else { return [] }
        let grammar = Language(language: tree_sitter_css())
        let parsed: (Parser, MutableTree)?
        if let documentID {
            parsed = TreeSitterCodeCache.shared.parse(
                string: string,
                revision: revision,
                documentID: documentID,
                edit: edit,
                language: grammar,
                namespace: "css",
                isCancelled: isCancelled
            )
        } else {
            let parser = Parser()
            do { try parser.setLanguage(grammar) } catch { return [] }
            parsed = parser.parse(string).map { (parser, $0) }
        }
        guard let (_, tree) = parsed,
              let root = tree.rootNode,
              !isCancelled() else { return [] }

        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        let requested = NSIntersectionRange(range, fullRange)
        var result: [SyntaxHighlighter.Token] = []
        func visit(_ node: Node) {
            if isCancelled() { return }
            if let nodeType = node.nodeType,
               let kind = Self.tokenKind(for: nodeType) {
                let nodeRange = UTF16TreeRange.range(
                    for: node.byteRange,
                    stringLength: fullRange.length
                )
                let clipped = NSIntersectionRange(nodeRange, requested)
                if clipped.length > 0 {
                    result.append(.init(range: clipped, kind: kind))
                }
            }
            for index in 0..<node.childCount {
                guard let child = node.child(at: index) else { continue }
                visit(child)
            }
        }
        visit(root)
        return result
    }

    private static func tokenKind(
        for nodeType: String
    ) -> SyntaxHighlighter.TokenKind? {
        switch nodeType {
        case "comment", "js_comment": return .comment
        case "string_value", "string_content": return .string
        case "integer_value", "float_value": return .number
        case "color_value": return .literal
        case "property_name": return .property
        case "class_name", "tag_name", "identifier": return .variable
        case "selector", "class_selector", "id_selector", "pseudo_class_selector":
            return .selector
        default: return nil
        }
    }
}

struct TreeSitterHTMLBackend: SyntaxParserBackend {
    static let maximumUTF8Bytes = TreeSitterJavaScriptBackend.maximumUTF8Bytes

    func tokens(
        in string: String,
        language: EditorLanguage,
        range: NSRange,
        context _: SyntaxHighlighter.IncrementalContext?,
        revision: UInt?,
        documentID: UUID?,
        edit: DocumentEditDelta?,
        isCancelled: @escaping () -> Bool
    ) -> [SyntaxHighlighter.Token] {
        guard language == .html,
              string.utf8.count <= Self.maximumUTF8Bytes,
              !isCancelled() else { return [] }
        let grammar = Language(language: tree_sitter_html())
        let parsed: (Parser, MutableTree)?
        if let documentID {
            parsed = TreeSitterCodeCache.shared.parse(
                string: string,
                revision: revision,
                documentID: documentID,
                edit: edit,
                language: grammar,
                namespace: "html",
                isCancelled: isCancelled
            )
        } else {
            let parser = Parser()
            do { try parser.setLanguage(grammar) } catch { return [] }
            parsed = parser.parse(string).map { (parser, $0) }
        }
        guard let (_, tree) = parsed,
              let root = tree.rootNode,
              !isCancelled() else { return [] }

        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        let requested = NSIntersectionRange(range, fullRange)
        var result: [SyntaxHighlighter.Token] = []
        func visit(_ node: Node) {
            if isCancelled() { return }
            if let nodeType = node.nodeType,
               let kind = Self.tokenKind(for: nodeType) {
                let nodeRange = UTF16TreeRange.range(
                    for: node.byteRange,
                    stringLength: fullRange.length
                )
                let clipped = NSIntersectionRange(nodeRange, requested)
                if clipped.length > 0 {
                    result.append(.init(range: clipped, kind: kind))
                }
            }
            for index in 0..<node.childCount {
                guard let child = node.child(at: index) else { continue }
                visit(child)
            }
        }
        visit(root)
        return result
    }

    private static func tokenKind(
        for nodeType: String
    ) -> SyntaxHighlighter.TokenKind? {
        switch nodeType {
        case "comment": return .comment
        case "doctype": return .keyword
        case "start_tag", "end_tag", "self_closing_tag", "element", "script_element", "style_element":
            return .markup
        case "tag_name", "erroneous_end_tag_name": return .heading
        case "attribute", "attribute_name": return .attribute
        case "attribute_value", "quoted_attribute_value": return .string
        default: return nil
        }
    }
}

private enum UTF16TreeRange {
    static func range(for bytes: Range<UInt32>, stringLength: Int) -> NSRange {
        let start = min(stringLength, Int(bytes.lowerBound) / 2)
        let end = min(stringLength, Int(bytes.upperBound) / 2)
        return NSRange(location: start, length: max(0, end - start))
    }
}

private final class TreeSitterCodeCache: @unchecked Sendable {
    static let shared = TreeSitterCodeCache()

    private struct Key: Hashable {
        let documentID: UUID
        let namespace: String
    }

    private final class Entry {
        let parser: Parser
        var tree: MutableTree
        var text: String
        var revision: UInt?

        init(parser: Parser, tree: MutableTree, text: String, revision: UInt?) {
            self.parser = parser
            self.tree = tree
            self.text = text
            self.revision = revision
        }
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private let maximumEntries = 8

    func parse(
        string: String,
        revision: UInt?,
        documentID: UUID,
        edit: DocumentEditDelta?,
        language: Language,
        namespace: String,
        isCancelled: @escaping () -> Bool
    ) -> (Parser, MutableTree)? {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled() else { return nil }

        let key = Key(documentID: documentID, namespace: namespace)
        if let entry = entries[key],
           entry.revision == revision,
           entry.text == string {
            return (entry.parser, entry.tree)
        }

        if let previous = entries[key],
           let edit,
           let revision,
           previous.revision.map({ $0 &+ 1 }) == revision,
           previous.text.utf16.count >= edit.editedRange.upperBound,
           editMatchesCachedText(edit, old: previous.text, new: string) {
            let oldMap = TreeSitterPointMap(previous.text)
            let newMap = TreeSitterPointMap(string)
            let inputEdit = InputEdit(
                startByte: oldMap.byteOffset(at: edit.editedRange.location),
                oldEndByte: oldMap.byteOffset(at: edit.editedRange.upperBound),
                newEndByte: newMap.byteOffset(
                    at: edit.editedRange.location + edit.replacementLength
                ),
                startPoint: oldMap.point(at: edit.editedRange.location),
                oldEndPoint: oldMap.point(at: edit.editedRange.upperBound),
                newEndPoint: newMap.point(
                    at: edit.editedRange.location + edit.replacementLength
                )
            )
            previous.tree.edit(inputEdit)
            guard !isCancelled(),
                  let updatedTree = previous.parser.parse(
                      tree: previous.tree,
                      string: string
                  ) else { return nil }
            previous.tree = updatedTree
            previous.text = string
            previous.revision = revision
            return (previous.parser, previous.tree)
        }

        let parser = Parser()
        do {
            try parser.setLanguage(language)
        } catch {
            return nil
        }
        guard let tree = parser.parse(string), !isCancelled() else { return nil }
        let entry = Entry(parser: parser, tree: tree, text: string, revision: revision)
        entries[key] = entry
        if entries.count > maximumEntries, let firstKey = entries.keys.first {
            entries.removeValue(forKey: firstKey)
        }
        return (entry.parser, entry.tree)
    }

    private func editMatchesCachedText(
        _ edit: DocumentEditDelta,
        old: String,
        new: String
    ) -> Bool {
        let oldText = old as NSString
        let newText = new as NSString
        let oldEnd = edit.editedRange.upperBound
        let newEnd = edit.editedRange.location + edit.replacementLength
        guard oldEnd <= oldText.length,
              newEnd <= newText.length else { return false }
        let prefixLength = edit.editedRange.location
        if prefixLength > 0 {
            let oldPrefix = oldText.substring(with: NSRange(location: 0, length: prefixLength))
            let newPrefix = newText.substring(with: NSRange(location: 0, length: prefixLength))
            guard oldPrefix == newPrefix else { return false }
        }
        let oldSuffixLength = oldText.length - oldEnd
        let newSuffixLength = newText.length - newEnd
        guard oldSuffixLength == newSuffixLength else { return false }
        if oldSuffixLength > 0 {
            let oldSuffix = oldText.substring(with: NSRange(location: oldEnd, length: oldSuffixLength))
            let newSuffix = newText.substring(with: NSRange(location: newEnd, length: newSuffixLength))
            return oldSuffix == newSuffix
        }
        return true
    }

    func remove(documentID: UUID) {
        lock.lock()
        entries.keys.filter { $0.documentID == documentID }.forEach {
            entries.removeValue(forKey: $0)
        }
        lock.unlock()
    }
}

struct TreeSitterGenericBackend: SyntaxParserBackend {
    let supportedLanguage: EditorLanguage
    let namespace: String
    let grammar: Language

    static let maximumUTF8Bytes = 20 * 1_024 * 1_024

    func tokens(
        in string: String,
        language: EditorLanguage,
        range: NSRange,
        context _: SyntaxHighlighter.IncrementalContext?,
        revision: UInt?,
        documentID: UUID?,
        edit: DocumentEditDelta?,
        isCancelled: @escaping () -> Bool
    ) -> [SyntaxHighlighter.Token] {
        guard language == supportedLanguage,
              string.utf8.count <= Self.maximumUTF8Bytes,
              !isCancelled() else { return [] }
        let parsed: (Parser, MutableTree)?
        if let documentID {
            parsed = TreeSitterCodeCache.shared.parse(
                string: string, revision: revision, documentID: documentID,
                edit: edit, language: grammar, namespace: namespace,
                isCancelled: isCancelled
            )
        } else {
            let parser = Parser()
            do { try parser.setLanguage(grammar) } catch { return [] }
            parsed = parser.parse(string).map { (parser, $0) }
        }
        guard let (_, tree) = parsed,
              let root = tree.rootNode,
              !isCancelled() else { return [] }
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        let requested = NSIntersectionRange(range, fullRange)
        var result: [SyntaxHighlighter.Token] = []
        func visit(_ node: Node) {
            if isCancelled() { return }
            if let nodeType = node.nodeType,
               let kind = Self.tokenKind(for: nodeType, language: supportedLanguage) {
                let nodeRange = UTF16TreeRange.range(for: node.byteRange, stringLength: fullRange.length)
                let clipped = NSIntersectionRange(nodeRange, requested)
                if clipped.length > 0 { result.append(.init(range: clipped, kind: kind)) }
            }
            for index in 0..<node.childCount {
                guard let child = node.child(at: index) else { continue }
                visit(child)
            }
        }
        visit(root)
        return result
    }

    private static func tokenKind(for nodeType: String, language: EditorLanguage) -> SyntaxHighlighter.TokenKind? {
        let type = nodeType.lowercased()
        if type.contains("comment") { return .comment }
        if type.contains("string") || type.contains("char_literal") || type == "raw_string" { return .string }
        if type == "number" || type == "integer" || type == "float" || type == "double"
            || type.hasSuffix("_number") || type.hasSuffix("_integer") || type.hasSuffix("_float") {
            return .number
        }
        if ["true", "false", "null", "none", "nil", "boolean", "boolean_literal", "true_literal", "false_literal"].contains(type) {
            return .literal
        }
        if ["function_name", "method_name", "constructor_name", "function_identifier", "callable_name"].contains(type) {
            return .function
        }
        if ["type_identifier", "_type_identifier", "type_name", "class_name", "struct_name", "enum_name", "protocol_name", "interface_name"].contains(type) {
            return .typeName
        }
        if ["property_identifier", "field_identifier", "attribute_name", "key", "key_name", "property_name"].contains(type) {
            return .property
        }
        if ["identifier", "variable_name", "variable", "constant", "constant_name", "name"].contains(type) {
            return .variable
        }
        if type == "operator" || type.hasSuffix("_operator") { return .punctuation }
        if language == .yaml && (type.contains("scalar") || type.contains("anchor") || type.contains("tag")) { return .variable }
        return nil
    }
}

private struct TreeSitterPointMap {
    private let text: NSString

    init(_ string: String) { text = string as NSString }

    func byteOffset(at utf16Offset: Int) -> Int {
        min(max(0, utf16Offset), text.length) * 2
    }

    func point(at utf16Offset: Int) -> Point {
        let bounded = min(max(0, utf16Offset), text.length)
        var row = 0
        var lineStart = 0
        var index = 0
        while index < bounded {
            if text.character(at: index) == 0x0A {
                row += 1
                lineStart = index + 1
            }
            index += 1
        }
        return Point(row: row, column: bounded - lineStart)
    }
}
#endif

enum SyntaxParserRegistry {
    /// Route each document to exactly one parser. Tree-sitter handles supported
    /// code languages under the same size gate; JSON and Markdown retain their
    /// dedicated parsers and large documents retain the lightweight fallback.
    static func backend(for language: EditorLanguage) -> any SyntaxParserBackend {
#if canImport(SwiftTreeSitter) && canImport(TreeSitterJavaScript) && canImport(TreeSitterTypeScript) && canImport(TreeSitterPython) && canImport(TreeSitterCSS) && canImport(TreeSitterHTML) && canImport(TreeSitterSwift) && canImport(TreeSitterBash) && canImport(TreeSitterYAML) && canImport(TreeSitterC) && canImport(TreeSitterCPP) && canImport(TreeSitterSQL)
        if language == .javascript {
            return TreeSitterJavaScriptBackend()
        }
        if language == .typescript {
            return TreeSitterTypeScriptBackend()
        }
        if language == .python {
            return TreeSitterPythonBackend()
        }
        if language == .css {
            return TreeSitterCSSBackend()
        }
        if language == .html {
            return TreeSitterHTMLBackend()
        }
        if language == .swift {
            return TreeSitterGenericBackend(supportedLanguage: .swift, namespace: "swift", grammar: Language(language: tree_sitter_swift()))
        }
        if language == .shell {
            return TreeSitterGenericBackend(supportedLanguage: .shell, namespace: "bash", grammar: Language(language: tree_sitter_bash()))
        }
        if language == .yaml {
            return TreeSitterGenericBackend(supportedLanguage: .yaml, namespace: "yaml", grammar: Language(language: tree_sitter_yaml()))
        }
        if language == .cFamily {
            return TreeSitterGenericBackend(supportedLanguage: .cFamily, namespace: "cpp", grammar: Language(language: tree_sitter_cpp()))
        }
        if language == .sql {
            return TreeSitterGenericBackend(supportedLanguage: .sql, namespace: "sql", grammar: Language(language: tree_sitter_sql()))
        }
#endif
        return LexicalSyntaxParserBackend()
    }
}
