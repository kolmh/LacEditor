import AppKit
import CoreFoundation
import Foundation
import UniformTypeIdentifiers

struct DecodedFile {
    let text: String
    let encoding: String.Encoding
    let encodingName: String
    let byteCount: Int
    let lineCount: Int
}

struct DocumentFileIdentity: Hashable, Sendable {
    let canonicalPath: String
    let resourceIdentifier: String?

    static func resolve(_ url: URL) -> Self {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let values = try? canonicalURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
        return Self(
            canonicalPath: canonicalURL.path,
            resourceIdentifier: values?.fileResourceIdentifier.map(String.init(describing:))
        )
    }

    func matches(_ other: Self) -> Bool {
        if let resourceIdentifier, let otherIdentifier = other.resourceIdentifier {
            return resourceIdentifier == otherIdentifier
        }
        return canonicalPath == other.canonicalPath
    }
}

struct FileRevisionSnapshot: Equatable, Sendable {
    let identity: DocumentFileIdentity
    let modificationDate: Date?
    let fileSize: Int?

    nonisolated static func capture(_ url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [
            .fileResourceIdentifierKey,
            .contentModificationDateKey,
            .fileSizeKey
        ])
        return Self(
            identity: DocumentFileIdentity.resolve(url),
            modificationDate: values.contentModificationDate,
            fileSize: values.fileSize
        )
    }
}

struct FileEncodingChoice: Sendable {
    let name: String
    let encoding: String.Encoding
}

enum PreparedFileRead {
    case decoded(DecodedFile)
    case needsEncoding(Data, byteCount: Int)
}

enum FileServiceError: LocalizedError {
    case unsupportedEncoding
    case unrepresentableCharacters(String)
    case invalidFileName
    case destinationExists

    var errorDescription: String? {
        switch self {
        case .unsupportedEncoding:
            "无法使用所选编码读取文件。"
        case let .unrepresentableCharacters(encodingName):
            "当前内容包含无法使用\(encodingName)保存的字符。"
        case .invalidFileName:
            "文件名不能为空，也不能包含“/”。"
        case .destinationExists:
            "同一文件夹中已存在同名文件。"
        }
    }
}

@MainActor
final class FileService {
    nonisolated static let supportedExtensions = [
        "txt", "md", "markdown", "html", "htm", "json",
        "js", "mjs", "cjs", "ts", "tsx", "css", "py", "pyw", "swift",
        "sh", "bash", "zsh", "yaml", "yml", "c", "h", "cc", "cpp",
        "cxx", "hpp", "sql"
    ]

    func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.supportedContentTypes
        return panel.runModal() == .OK ? panel.urls : []
    }

    func chooseSaveURL(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = Self.supportedContentTypes
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    func read(_ url: URL) throws -> DecodedFile {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) {
            return DecodedFile(
                text: text,
                encoding: .utf8,
                encodingName: "UTF-8",
                byteCount: data.count,
                lineCount: Self.countLines(in: text)
            )
        }

        return try decodeUsingSelectedEncoding(data, from: url)
    }

    nonisolated static func prepareRead(_ url: URL) throws -> PreparedFileRead {
        let byteCount = try fileByteCount(at: url)
        let options: Data.ReadingOptions = byteCount > 20 * 1_024 * 1_024
            ? .mappedIfSafe
            : []
        let data = try Data(contentsOf: url, options: options)
        if let text = String(data: data, encoding: .utf8) {
            return .decoded(DecodedFile(
                text: text,
                encoding: .utf8,
                encodingName: "UTF-8",
                byteCount: byteCount,
                lineCount: countLines(in: text)
            ))
        }
        return .needsEncoding(data, byteCount: byteCount)
    }

    nonisolated static func fileByteCount(at url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize ?? 0
    }

    func decodeUsingSelectedEncoding(
        _ data: Data,
        from url: URL,
        byteCount: Int? = nil
    ) throws -> DecodedFile {

        guard let selected = chooseEncoding(for: url) else {
            throw CocoaError(.userCancelled)
        }
        return try Self.decode(
            data,
            encoding: selected.encoding,
            encodingName: selected.name,
            byteCount: byteCount
        )
    }

    func chooseEncoding(for url: URL) -> FileEncodingChoice? {
        let choices = Self.selectableEncodings
        let alert = NSAlert()
        alert.messageText = "请选择文件编码"
        alert.informativeText = "“\(url.lastPathComponent)”不是有效的 UTF-8 文件。请选择用于打开它的文本编码。"
        alert.addButton(withTitle: "打开")
        alert.addButton(withTitle: "取消")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        popup.addItems(withTitles: choices.map(\.name))
        alert.accessoryView = popup

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return choices[popup.indexOfSelectedItem]
    }

    nonisolated static func decode(
        _ data: Data,
        encoding: String.Encoding,
        encodingName: String,
        byteCount: Int? = nil
    ) throws -> DecodedFile {
        guard let text = String(data: data, encoding: encoding) else {
            throw FileServiceError.unsupportedEncoding
        }
        return DecodedFile(
            text: text,
            encoding: encoding,
            encodingName: encodingName,
            byteCount: byteCount ?? data.count,
            lineCount: countLines(in: text)
        )
    }

    func write(_ text: String, to url: URL) throws {
        try Self.writeUTF8(text, to: url)
    }

    nonisolated static func writeUTF8(_ text: String, to url: URL) throws {
        try write(text, to: url, encoding: .utf8, encodingName: "UTF-8")
    }

    nonisolated static func write(
        _ text: String,
        to url: URL,
        encoding: String.Encoding,
        encodingName: String
    ) throws {
        guard let data = text.data(using: encoding, allowLossyConversion: false) else {
            throw FileServiceError.unrepresentableCharacters(encodingName)
        }
        try data.write(to: url, options: .atomic)
    }

    nonisolated static func encodingName(for encoding: String.Encoding) -> String {
        if encoding == .utf8 { return "UTF-8" }
        if encoding == .utf16 { return "UTF-16" }
        if encoding == gb18030Encoding { return "简体中文（GB 18030）" }
        if encoding == .isoLatin1 { return "西欧（ISO Latin 1）" }
        if encoding == .windowsCP1252 { return "西欧（Windows Latin 1）" }
        if encoding == .macOSRoman { return "Mac OS 罗马编码" }
        return "编码 \(encoding.rawValue)"
    }

    nonisolated static let gb18030Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(0x0632)
        )
    )

    nonisolated static let selectableEncodings: [FileEncodingChoice] = [
        FileEncodingChoice(name: "UTF-16", encoding: .utf16),
        FileEncodingChoice(name: "简体中文（GB 18030）", encoding: gb18030Encoding),
        FileEncodingChoice(name: "西欧（ISO Latin 1）", encoding: .isoLatin1),
        FileEncodingChoice(name: "西欧（Windows Latin 1）", encoding: .windowsCP1252),
        FileEncodingChoice(name: "Mac OS 罗马编码", encoding: .macOSRoman)
    ]

    nonisolated private static func countLines(in text: String) -> Int {
        var count = 1
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                if !previousWasCR { count += 1 }
                previousWasCR = false
            case 0x0D:
                count += 1
                previousWasCR = true
            case 0x2028, 0x2029:
                count += 1
                previousWasCR = false
            default:
                previousWasCR = false
            }
        }
        return count
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

    static var supportedContentTypes: [UTType] {
        Self.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    }
}
