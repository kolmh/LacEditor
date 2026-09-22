import Foundation

struct WorkspaceSessionSnapshot: Equatable, Sendable {
    let windows: [WorkspaceWindowSnapshot]
}

struct WorkspaceWindowSnapshot: Equatable, Sendable {
    let documents: [WorkspaceDocumentSnapshot]
    let selectedDocumentID: UUID?
    let isSidebarVisible: Bool
    let frame: WorkspaceWindowFrame?
}

struct WorkspaceDocumentSnapshot: Equatable, Sendable {
    let documentID: UUID
    let text: String
    let sourceURL: URL?
    let language: EditorLanguage
    let encoding: String.Encoding
    let isDirty: Bool
    let selectionRange: NSRange
    let scrollPositionRatio: CGFloat
    let isPreviewVisible: Bool
    let fileRevisionSnapshot: FileRevisionSnapshot?
}

struct WorkspaceWindowFrame: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

final class WorkspaceSessionStore: @unchecked Sendable {
    private struct Marker: Codable {
        let workspaceID: UUID
    }

    private struct Manifest: Codable {
        let version: Int
        let windows: [WindowMetadata]
    }

    private struct WindowMetadata: Codable {
        let documents: [DocumentMetadata]
        let selectedDocumentID: UUID?
        let isSidebarVisible: Bool
        let frame: WorkspaceWindowFrame?
    }

    private struct DocumentMetadata: Codable {
        let documentID: UUID
        let contentFileName: String
        let sourcePath: String?
        let language: String
        let encodingRawValue: UInt
        let isDirty: Bool
        let selectionLocation: Int
        let selectionLength: Int
        let scrollPositionRatio: Double
        let isPreviewVisible: Bool
        let canonicalPath: String?
        let resourceIdentifier: String?
        let modificationDate: Date?
        let fileSize: Int?
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(
        label: "com.laceditor.workspace-session",
        qos: .utility
    )

    init(
        rootURL: URL = WorkspaceSessionStore.defaultRootURL(),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func save(
        _ snapshot: WorkspaceSessionSnapshot,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        queue.async { [self] in
            let result = Result { try saveLocked(snapshot) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    func loadAndConsume() throws -> WorkspaceSessionSnapshot? {
        try queue.sync {
            guard let marker = try readMarker() else { return nil }
            let directory = workspaceURL(for: marker.workspaceID)
            let manifestURL = directory.appendingPathComponent("Manifest.json")
            let manifest = try JSONDecoder().decode(
                Manifest.self,
                from: Data(contentsOf: manifestURL, options: .mappedIfSafe)
            )
            guard manifest.version == 1 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let windows = try manifest.windows.map { window in
                WorkspaceWindowSnapshot(
                    documents: try window.documents.map { document in
                        let contentURL = directory.appendingPathComponent(
                            document.contentFileName
                        )
                        let data = try Data(
                            contentsOf: contentURL,
                            options: .mappedIfSafe
                        )
                        let baseline = document.canonicalPath.map {
                            FileRevisionSnapshot(
                                identity: DocumentFileIdentity(
                                    canonicalPath: $0,
                                    resourceIdentifier: document.resourceIdentifier
                                ),
                                modificationDate: document.modificationDate,
                                fileSize: document.fileSize
                            )
                        }
                        return WorkspaceDocumentSnapshot(
                            documentID: document.documentID,
                            text: String(decoding: data, as: UTF8.self),
                            sourceURL: document.sourcePath.map {
                                URL(fileURLWithPath: $0).standardizedFileURL
                            },
                            language: EditorLanguage(rawValue: document.language)
                                ?? .plainText,
                            encoding: String.Encoding(
                                rawValue: document.encodingRawValue
                            ),
                            isDirty: document.isDirty,
                            selectionRange: NSRange(
                                location: document.selectionLocation,
                                length: document.selectionLength
                            ),
                            scrollPositionRatio: CGFloat(
                                document.scrollPositionRatio
                            ),
                            isPreviewVisible: document.isPreviewVisible,
                            fileRevisionSnapshot: baseline
                        )
                    },
                    selectedDocumentID: window.selectedDocumentID,
                    isSidebarVisible: window.isSidebarVisible,
                    frame: window.frame
                )
            }
            try? fileManager.removeItem(at: markerURL)
            try? fileManager.removeItem(at: directory)
            removeWorkspaceDirectories(except: nil)
            return WorkspaceSessionSnapshot(windows: windows)
        }
    }

    func clear(completion: @escaping @MainActor @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { completion() }
                }
                return
            }
            try? fileManager.removeItem(at: markerURL)
            removeWorkspaceDirectories(except: nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion() }
            }
        }
    }

    func saveForTesting(_ snapshot: WorkspaceSessionSnapshot) throws {
        try queue.sync { try saveLocked(snapshot) }
    }

    private func saveLocked(_ snapshot: WorkspaceSessionSnapshot) throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let workspaceID = UUID()
        let stagingURL = rootURL.appendingPathComponent(
            "Workspace-\(workspaceID.uuidString.lowercased()).tmp",
            isDirectory: true
        )
        let finalURL = workspaceURL(for: workspaceID)
        try? fileManager.removeItem(at: stagingURL)
        try fileManager.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: true
        )

        do {
            var metadataWindows: [WindowMetadata] = []
            for window in snapshot.windows {
                var metadataDocuments: [DocumentMetadata] = []
                for document in window.documents {
                    let contentFileName = "\(document.documentID.uuidString.lowercased()).utf8"
                    try Data(document.text.utf8).write(
                        to: stagingURL.appendingPathComponent(contentFileName),
                        options: .atomic
                    )
                    let baseline = document.fileRevisionSnapshot
                    metadataDocuments.append(DocumentMetadata(
                        documentID: document.documentID,
                        contentFileName: contentFileName,
                        sourcePath: document.sourceURL?.standardizedFileURL.path,
                        language: document.language.rawValue,
                        encodingRawValue: document.encoding.rawValue,
                        isDirty: document.isDirty,
                        selectionLocation: document.selectionRange.location,
                        selectionLength: document.selectionRange.length,
                        scrollPositionRatio: Double(document.scrollPositionRatio),
                        isPreviewVisible: document.isPreviewVisible,
                        canonicalPath: baseline?.identity.canonicalPath,
                        resourceIdentifier: baseline?.identity.resourceIdentifier,
                        modificationDate: baseline?.modificationDate,
                        fileSize: baseline?.fileSize
                    ))
                }
                metadataWindows.append(WindowMetadata(
                    documents: metadataDocuments,
                    selectedDocumentID: window.selectedDocumentID,
                    isSidebarVisible: window.isSidebarVisible,
                    frame: window.frame
                ))
            }

            let manifest = Manifest(version: 1, windows: metadataWindows)
            try JSONEncoder().encode(manifest).write(
                to: stagingURL.appendingPathComponent("Manifest.json"),
                options: .atomic
            )
            try fileManager.moveItem(at: stagingURL, to: finalURL)
            try JSONEncoder().encode(Marker(workspaceID: workspaceID)).write(
                to: markerURL,
                options: .atomic
            )
            removeWorkspaceDirectories(except: workspaceID)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            try? fileManager.removeItem(at: finalURL)
            throw error
        }
    }

    private var markerURL: URL {
        rootURL.appendingPathComponent("CurrentWorkspace.json")
    }

    private func workspaceURL(for workspaceID: UUID) -> URL {
        rootURL.appendingPathComponent(
            "Workspace-\(workspaceID.uuidString.lowercased())",
            isDirectory: true
        )
    }

    private func readMarker() throws -> Marker? {
        guard fileManager.fileExists(atPath: markerURL.path) else { return nil }
        return try JSONDecoder().decode(
            Marker.self,
            from: Data(contentsOf: markerURL)
        )
    }

    private func removeWorkspaceDirectories(except workspaceID: UUID?) {
        let retainedURL = workspaceID.map(workspaceURL)?.standardizedFileURL
        for candidate in (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? [] where candidate.lastPathComponent.hasPrefix("Workspace-")
            && candidate.standardizedFileURL != retainedURL {
            try? fileManager.removeItem(at: candidate)
        }
    }

    private static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let directory = Bundle.main.bundleIdentifier == "com.laceditor.acceptance"
            ? "LacEditor-Acceptance" : "LacEditor"
        return base.appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("Workspace", isDirectory: true)
    }
}
