import Foundation

struct DocumentRecoverySnapshot: Equatable, Sendable {
    let documentID: UUID
    let text: String
    let sourceURL: URL?
    let language: EditorLanguage
    let encoding: String.Encoding
    let revision: UInt
    let selectionRange: NSRange
    let scrollPositionRatio: CGFloat
    let isPreviewVisible: Bool
    let fileRevisionSnapshot: FileRevisionSnapshot?
    let capturedAt: Date
}

final class DocumentRecoveryStore: @unchecked Sendable {
    private struct SessionMarker: Codable {
        let sessionID: UUID
    }

    private struct SnapshotMetadata: Codable {
        let documentID: UUID
        let sourcePath: String?
        let language: String
        let encodingRawValue: UInt
        let revision: UInt
        let selectionLocation: Int
        let selectionLength: Int
        let scrollPositionRatio: Double
        let isPreviewVisible: Bool
        let canonicalPath: String?
        let resourceIdentifier: String?
        let modificationDate: Date?
        let fileSize: Int?
        let capturedAt: Date
        let contentFileName: String
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(
        label: "com.laceditor.document-recovery",
        qos: .utility
    )
    private var currentSessionID: UUID?

    init(
        rootURL: URL = DocumentRecoveryStore.defaultRootURL(),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func startSession() throws -> [DocumentRecoverySnapshot] {
        try queue.sync {
            if currentSessionID != nil { return [] }
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )

            let previousSessionID = try readMarker()?.sessionID
            let recovered = previousSessionID.map(loadSnapshots) ?? []
            let sessionID = UUID()
            currentSessionID = sessionID
            try fileManager.createDirectory(
                at: sessionURL(for: sessionID),
                withIntermediateDirectories: true
            )

            // Copy recovered records into the new session before switching the
            // marker, so another crash during launch still leaves one complete set.
            for snapshot in recovered {
                try persistLocked(snapshot)
            }
            try writeMarker(SessionMarker(sessionID: sessionID))
            removeSessionDirectories(except: sessionID)
            return recovered
        }
    }

    func persist(_ snapshot: DocumentRecoverySnapshot) {
        queue.async { [weak self] in
            guard let self else { return }
            try? persistLocked(snapshot)
        }
    }

    func discard(documentID: UUID) {
        queue.async { [weak self] in
            self?.discardLocked(documentID: documentID)
        }
    }

    func discard(documentIDs: [UUID]) {
        queue.async { [weak self] in
            guard let self else { return }
            for documentID in documentIDs {
                discardLocked(documentID: documentID)
            }
        }
    }

    func finishCleanly(completion: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            defer { DispatchQueue.main.async(execute: completion) }
            guard let self, let sessionID = currentSessionID else { return }
            try? fileManager.removeItem(at: sessionURL(for: sessionID))
            if (try? readMarker()?.sessionID) == sessionID {
                try? fileManager.removeItem(at: markerURL)
            }
            currentSessionID = nil
        }
    }

    func flushForTesting() {
        queue.sync {}
    }

    func finishCleanlyForTesting() {
        queue.sync {
            guard let sessionID = currentSessionID else { return }
            try? fileManager.removeItem(at: sessionURL(for: sessionID))
            if (try? readMarker()?.sessionID) == sessionID {
                try? fileManager.removeItem(at: markerURL)
            }
            currentSessionID = nil
        }
    }

    private func persistLocked(_ snapshot: DocumentRecoverySnapshot) throws {
        guard let sessionID = currentSessionID else { return }
        let directory = sessionURL(for: sessionID)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let stem = snapshot.documentID.uuidString.lowercased()
        let contentFileName = "\(stem)-\(snapshot.revision).utf8"
        let contentURL = directory.appendingPathComponent(contentFileName)
        try Data(snapshot.text.utf8).write(to: contentURL, options: .atomic)

        let baseline = snapshot.fileRevisionSnapshot
        let metadata = SnapshotMetadata(
            documentID: snapshot.documentID,
            sourcePath: snapshot.sourceURL?.standardizedFileURL.path,
            language: snapshot.language.rawValue,
            encodingRawValue: snapshot.encoding.rawValue,
            revision: snapshot.revision,
            selectionLocation: snapshot.selectionRange.location,
            selectionLength: snapshot.selectionRange.length,
            scrollPositionRatio: Double(snapshot.scrollPositionRatio),
            isPreviewVisible: snapshot.isPreviewVisible,
            canonicalPath: baseline?.identity.canonicalPath,
            resourceIdentifier: baseline?.identity.resourceIdentifier,
            modificationDate: baseline?.modificationDate,
            fileSize: baseline?.fileSize,
            capturedAt: snapshot.capturedAt,
            contentFileName: contentFileName
        )
        let metadataURL = directory.appendingPathComponent("\(stem).json")
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)

        let prefix = "\(stem)-"
        for candidate in (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? [] where candidate.lastPathComponent.hasPrefix(prefix)
            && candidate.lastPathComponent != contentFileName {
            try? fileManager.removeItem(at: candidate)
        }
    }

    private func loadSnapshots(sessionID: UUID) -> [DocumentRecoverySnapshot] {
        let directory = sessionURL(for: sessionID)
        let metadataURLs = ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? [])
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return metadataURLs.compactMap { metadataURL in
            guard let metadataData = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONDecoder().decode(
                    SnapshotMetadata.self,
                    from: metadataData
                  ),
                  let text = try? String(
                    contentsOf: directory.appendingPathComponent(
                        metadata.contentFileName
                    ),
                    encoding: .utf8
                  ),
                  let language = EditorLanguage(rawValue: metadata.language)
            else {
                return nil
            }
            let sourceURL = metadata.sourcePath.map {
                URL(fileURLWithPath: $0).standardizedFileURL
            }
            let baseline: FileRevisionSnapshot?
            if let canonicalPath = metadata.canonicalPath {
                baseline = FileRevisionSnapshot(
                    identity: DocumentFileIdentity(
                        canonicalPath: canonicalPath,
                        resourceIdentifier: metadata.resourceIdentifier
                    ),
                    modificationDate: metadata.modificationDate,
                    fileSize: metadata.fileSize
                )
            } else {
                baseline = nil
            }
            return DocumentRecoverySnapshot(
                documentID: metadata.documentID,
                text: text,
                sourceURL: sourceURL,
                language: language,
                encoding: String.Encoding(rawValue: metadata.encodingRawValue),
                revision: metadata.revision,
                selectionRange: NSRange(
                    location: metadata.selectionLocation,
                    length: metadata.selectionLength
                ),
                scrollPositionRatio: CGFloat(metadata.scrollPositionRatio),
                isPreviewVisible: metadata.isPreviewVisible,
                fileRevisionSnapshot: baseline,
                capturedAt: metadata.capturedAt
            )
        }
        .sorted { $0.capturedAt < $1.capturedAt }
    }

    private func discardLocked(documentID: UUID) {
        guard let sessionID = currentSessionID else { return }
        let directory = sessionURL(for: sessionID)
        let stem = documentID.uuidString.lowercased()
        for candidate in (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? [] where candidate.lastPathComponent == "\(stem).json"
            || candidate.lastPathComponent.hasPrefix("\(stem)-") {
            try? fileManager.removeItem(at: candidate)
        }
    }

    private var markerURL: URL {
        rootURL.appendingPathComponent("ActiveSession.json")
    }

    private func sessionURL(for sessionID: UUID) -> URL {
        rootURL.appendingPathComponent(
            "Session-\(sessionID.uuidString.lowercased())",
            isDirectory: true
        )
    }

    private func readMarker() throws -> SessionMarker? {
        guard fileManager.fileExists(atPath: markerURL.path) else { return nil }
        return try JSONDecoder().decode(
            SessionMarker.self,
            from: Data(contentsOf: markerURL)
        )
    }

    private func writeMarker(_ marker: SessionMarker) throws {
        try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
    }

    private func removeSessionDirectories(except activeSessionID: UUID) {
        let activeURL = sessionURL(for: activeSessionID).standardizedFileURL
        for candidate in (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? [] where candidate.lastPathComponent.hasPrefix("Session-")
            && candidate.standardizedFileURL != activeURL {
            try? fileManager.removeItem(at: candidate)
        }
    }

    private static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LacEditor", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
    }
}
