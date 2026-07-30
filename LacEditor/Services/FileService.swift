import AppKit
import CoreFoundation
import Foundation
import UniformTypeIdentifiers

struct DecodedFile {
    let text: String
    let encoding: String.Encoding
    let encodingName: String
}

enum FileServiceError: LocalizedError {
    case unsupportedEncoding
    case invalidFileName
    case destinationExists

    var errorDescription: String? {
        switch self {
        case .unsupportedEncoding:
            "无法使用所选编码读取文件。"
        case .invalidFileName:
            "文件名不能为空，也不能包含“/”。"
        case .destinationExists:
            "同一文件夹中已存在同名文件。"
        }
    }
}

@MainActor
final class FileService {
    static let supportedExtensions = [
        "txt", "md", "markdown", "html", "htm", "json",
        "js", "mjs", "cjs", "ts", "tsx", "css", "py", "pyw", "swift",
        "sh", "bash", "zsh", "yaml", "yml", "c", "h", "cc", "cpp",
        "cxx", "hpp", "sql"
    ]

    func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = supportedContentTypes
        return panel.runModal() == .OK ? panel.urls : []
    }

    func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseSaveURL(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = supportedContentTypes
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    func read(_ url: URL) throws -> DecodedFile {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) {
            return DecodedFile(text: text, encoding: .utf8, encodingName: "UTF-8")
        }

        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(0x0632)
            )
        )
        let choices: [(String, String.Encoding)] = [
            ("UTF-16", .utf16),
            ("简体中文（GB 18030）", gb18030),
            ("西欧（ISO Latin 1）", .isoLatin1),
            ("西欧（Windows Latin 1）", .windowsCP1252),
            ("Mac OS Roman", .macOSRoman)
        ]
        let alert = NSAlert()
        alert.messageText = "请选择文件编码"
        alert.informativeText = "“\(url.lastPathComponent)”不是有效的 UTF-8 文件。请选择用于打开它的文本编码。"
        alert.addButton(withTitle: "打开")
        alert.addButton(withTitle: "取消")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        popup.addItems(withTitles: choices.map(\.0))
        alert.accessoryView = popup

        guard alert.runModal() == .alertFirstButtonReturn else {
            throw CocoaError(.userCancelled)
        }
        let selected = choices[popup.indexOfSelectedItem]
        guard let text = String(data: data, encoding: selected.1) else {
            throw FileServiceError.unsupportedEncoding
        }
        return DecodedFile(text: text, encoding: selected.1, encodingName: selected.0)
    }

    func write(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else {
            throw FileServiceError.unsupportedEncoding
        }
        try data.write(to: url, options: .atomic)
    }

    func rename(_ url: URL, to newName: String) throws -> URL {
        guard !newName.isEmpty, !newName.contains("/") else {
            throw FileServiceError.invalidFileName
        }
        guard newName != url.lastPathComponent else {
            return url.standardizedFileURL
        }

        let destination = url.deletingLastPathComponent()
            .appendingPathComponent(newName)
            .standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw FileServiceError.destinationExists
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    func loadTree(at root: URL) -> [FileTreeNode] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isHidden != true else { return nil }
            let isDirectory = values.isDirectory == true
            if !isDirectory && !Self.supportedExtensions.contains(url.pathExtension.lowercased()) {
                return nil
            }
            return FileTreeNode(
                url: url,
                isDirectory: isDirectory,
                children: isDirectory ? loadTree(at: url) : nil
            )
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var supportedContentTypes: [UTType] {
        Self.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    }
}
