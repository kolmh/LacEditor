import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("File verification failed: \(message)")
    }
}

@main
struct FileServiceVerification {
    @MainActor
    static func main() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "LacEditor-FileVerification-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let service = FileService()
        let sample = "LacEditor 文件往返验证\n第二行\tUTF-8 😀\n"

        for fileExtension in FileService.supportedExtensions {
            let url = root.appendingPathComponent("sample.\(fileExtension)")
            try service.write(sample, to: url)
            let decoded = try service.read(url)
            require(decoded.text == sample, "\(fileExtension) UTF-8 round trip")
            require(decoded.encoding == .utf8, "\(fileExtension) encoding value")
            require(decoded.encodingName == "UTF-8", "\(fileExtension) encoding label")
        }

        let largeLine = "LacEditor large-file UTF-8 验证 0123456789\n"
        let largeSample = String(
            repeating: largeLine,
            count: (4 * 1_024 * 1_024 / largeLine.utf8.count) + 1
        )
        require(largeSample.utf8.count >= 4 * 1_024 * 1_024, "large fixture is at least 4 MiB")
        let largeURL = root.appendingPathComponent("large-sample.txt")
        try service.write(largeSample, to: largeURL)
        let largeDecoded = try service.read(largeURL)
        require(largeDecoded.text == largeSample, "4 MiB UTF-8 round trip")
        require(largeDecoded.encoding == .utf8, "4 MiB encoding value")

        let original = root.appendingPathComponent("rename-source.txt")
        try service.write("重命名", to: original)
        let renamed = try service.rename(original, to: "rename-target.md")
        require(!fileManager.fileExists(atPath: original.path), "rename removes source")
        require(fileManager.fileExists(atPath: renamed.path), "rename creates destination")
        require(EditorLanguage.infer(from: renamed) == .markdown, "rename updates inferred language")

        let occupied = root.appendingPathComponent("occupied.txt")
        try service.write("已存在", to: occupied)
        do {
            _ = try service.rename(renamed, to: occupied.lastPathComponent)
            fatalError("File verification failed: existing destination was overwritten")
        } catch FileServiceError.destinationExists {
            // Expected.
        }

        do {
            _ = try service.rename(renamed, to: "bad/name.md")
            fatalError("File verification failed: invalid filename was accepted")
        } catch FileServiceError.invalidFileName {
            // Expected.
        }

        let unsupported = root.appendingPathComponent("ignored.bin")
        try Data([0, 1, 2]).write(to: unsupported)
        let hidden = root.appendingPathComponent(".hidden.txt")
        try service.write("隐藏", to: hidden)
        let nestedDirectory = root.appendingPathComponent("folder", isDirectory: true)
        try fileManager.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let tree = service.loadTree(at: root)
        require(
            tree.contains {
                $0.isDirectory
                    && $0.url.standardizedFileURL.path
                        == nestedDirectory.standardizedFileURL.path
            },
            "tree includes directories"
        )
        require(tree.contains { $0.url.pathExtension == "json" }, "tree includes supported files")
        require(
            !tree.contains {
                $0.url.standardizedFileURL.path == unsupported.standardizedFileURL.path
            },
            "tree excludes unsupported files"
        )
        require(
            !tree.contains {
                $0.url.standardizedFileURL.path == hidden.standardizedFileURL.path
            },
            "tree excludes hidden files"
        )

        print(
            "File service verification passed "
                + "(\(FileService.supportedExtensions.count) formats + 4 MiB round trip)"
        )
    }
}
