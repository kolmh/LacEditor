import Foundation
import XCTest
@testable import LacEditor

final class DocumentRecoveryStoreTests: XCTestCase {
    func testWorkspaceSessionRoundTripPreservesWindowsTabsAndContent() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceSessionStore(
            rootURL: directory.appendingPathComponent("Workspace")
        )
        let firstID = UUID()
        let secondID = UUID()
        let snapshot = WorkspaceSessionSnapshot(windows: [
            WorkspaceWindowSnapshot(
                documents: [
                    WorkspaceDocumentSnapshot(
                        documentID: firstID,
                        text: "未保存内容",
                        sourceURL: nil,
                        language: .markdown,
                        encoding: .utf8,
                        isDirty: true,
                        selectionRange: NSRange(location: 3, length: 2),
                        scrollPositionRatio: 0.4,
                        isPreviewVisible: true,
                        fileRevisionSnapshot: nil
                    ),
                    WorkspaceDocumentSnapshot(
                        documentID: secondID,
                        text: #"{"z":1,"a":2}"#,
                        sourceURL: directory.appendingPathComponent("config.json"),
                        language: .json,
                        encoding: .utf8,
                        isDirty: false,
                        selectionRange: NSRange(location: 5, length: 0),
                        scrollPositionRatio: 0.8,
                        isPreviewVisible: false,
                        fileRevisionSnapshot: nil
                    )
                ],
                selectedDocumentID: secondID,
                isSidebarVisible: false,
                frame: WorkspaceWindowFrame(
                    x: 120,
                    y: 160,
                    width: 1_100,
                    height: 720
                )
            ),
            WorkspaceWindowSnapshot(
                documents: [WorkspaceDocumentSnapshot(
                    documentID: UUID(),
                    text: "second window",
                    sourceURL: nil,
                    language: .plainText,
                    encoding: .utf8,
                    isDirty: true,
                    selectionRange: NSRange(location: 2, length: 0),
                    scrollPositionRatio: 0.2,
                    isPreviewVisible: false,
                    fileRevisionSnapshot: nil
                )],
                selectedDocumentID: nil,
                isSidebarVisible: true,
                frame: nil
            )
        ])

        try store.saveForTesting(snapshot)
        XCTAssertEqual(try store.loadAndConsume()?.snapshot, snapshot)
        XCTAssertNil(try store.loadAndConsume())
    }

    func testDamagedUTF8PreservesOriginalBytesAndRestoresHealthyTabs() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceSessionStore(rootURL: root)
        let damagedID = UUID()
        let healthyID = UUID()
        try store.saveForTesting(workspaceSnapshot(ids: [damagedID, healthyID]))
        let damagedURL = try workspaceContentURL(root: root, id: damagedID)
        let original = Data([0x41, 0xff, 0x42])
        try original.write(to: damagedURL)

        let result = try XCTUnwrap(store.loadAndConsume())
        XCTAssertEqual(result.skippedDocumentCount, 1)
        XCTAssertEqual(result.snapshot.windows.first?.documents.map(\.documentID), [healthyID])
        XCTAssertEqual(result.snapshot.windows.first?.selectedDocumentID, healthyID)
        let preserved = try preservedContentURL(root: root, id: damagedID)
        XCTAssertEqual(try Data(contentsOf: preserved), original)
        XCTAssertNil(try store.loadAndConsume())

        // A later successful save/consume must not clean up the damaged backup.
        try store.saveForTesting(workspaceSnapshot(ids: [healthyID]))
        _ = try store.loadAndConsume()
        XCTAssertEqual(try Data(contentsOf: preserved), original)
    }

    func testCorruptManifestAndMarkerArePreservedBeforeFutureSaves() throws {
        for corruptMarker in [false, true] {
            let root = makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = WorkspaceSessionStore(rootURL: root)
            let id = UUID()
            try store.saveForTesting(workspaceSnapshot(ids: [id]))
            let original = try Data(contentsOf: workspaceContentURL(root: root, id: id))
            let corruptURL = corruptMarker
                ? root.appendingPathComponent("CurrentWorkspace.json")
                : try workspaceContentURL(root: root, id: id).deletingLastPathComponent().appendingPathComponent("Manifest.json")
            try Data("invalid json".utf8).write(to: corruptURL)
            XCTAssertThrowsError(try store.loadAndConsume())
            let preserved = try preservedContentURL(root: root, id: id)
            XCTAssertEqual(try Data(contentsOf: preserved), original)
            try store.saveForTesting(workspaceSnapshot(ids: [UUID()]))
            _ = try store.loadAndConsume()
            XCTAssertEqual(try Data(contentsOf: preserved), original)
        }
    }

    @MainActor
    func testFailedPreservationBlocksSaveAndClearUntilRetrySucceeds() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceSessionStore(rootURL: root)
        let id = UUID()
        try store.saveForTesting(workspaceSnapshot(ids: [id]))
        let contentURL = try workspaceContentURL(root: root, id: id)
        let raw = Data([0xff, 0xfe])
        try raw.write(to: contentURL)
        let blocker = root.appendingPathComponent("Preserved")
        try Data("not a directory".utf8).write(to: blocker)
        let markerURL = root.appendingPathComponent("CurrentWorkspace.json")
        let originalMarker = try Data(contentsOf: markerURL)
        XCTAssertThrowsError(try store.loadAndConsume())
        XCTAssertThrowsError(try store.saveForTesting(workspaceSnapshot(ids: [UUID()])))
        let clearResult: Result<Void, Error> = await withCheckedContinuation { continuation in
            store.clear { continuation.resume(returning: $0) }
        }
        XCTAssertThrowsError(try clearResult.get())
        XCTAssertEqual(try Data(contentsOf: markerURL), originalMarker)
        XCTAssertEqual(try Data(contentsOf: contentURL), raw)

        try FileManager.default.removeItem(at: blocker)
        try store.saveForTesting(workspaceSnapshot(ids: [UUID()]))
        let preserved = try preservedContentURL(root: root, id: id)
        XCTAssertEqual(try Data(contentsOf: preserved), raw)
        let successfulClear: Result<Void, Error> = await withCheckedContinuation { continuation in
            store.clear { continuation.resume(returning: $0) }
        }
        XCTAssertNoThrow(try successfulClear.get())
        XCTAssertEqual(try Data(contentsOf: preserved), raw)
    }

    @MainActor
    func testWindowManagerReportsPartialAndFailedRestoration() throws {
        for corruptManifest in [false, true] {
            let root = makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = WorkspaceSessionStore(rootURL: root)
            let id = UUID()
            try store.saveForTesting(workspaceSnapshot(ids: [id]))
            let content = try workspaceContentURL(root: root, id: id)
            let target = corruptManifest ? content.deletingLastPathComponent().appendingPathComponent("Manifest.json") : content
            try Data([0xff]).write(to: target)
            let suite = "LacEditorRecoveryTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let manager = WindowManager(
                workspaceStore: store, preferences: AppPreferences(defaults: defaults),
                recentFiles: RecentFilesStore(defaults: defaults),
                sidebarLibrary: SidebarLibraryStore(storageURL: root.appendingPathComponent("Sidebar.json"))
            )
            XCTAssertNotNil(manager.restorationMessage)
            XCTAssertEqual(manager.restorationFilesURL, root)
            XCTAssertTrue(manager.takeRecoveredDocuments().isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Preserved").path))
        }
    }

    func testDuplicateRecoveryMetadataChoosesNewestTimestampThenRevision() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let store = DocumentRecoveryStore(rootURL: root)
        _ = try store.startSession()
        store.persist(makeSnapshot(documentID: id, text: "original", revision: 1))
        store.flushForTesting()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let metadataURL = try XCTUnwrap(enumerator.allObjects.compactMap { $0 as? URL }.first {
            $0.lastPathComponent == "\(id.uuidString.lowercased()).json"
        })
        let directory = metadataURL.deletingLastPathComponent()
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        metadata["revision"] = 2
        metadata["contentFileName"] = "newer.utf8"
        try Data("newer revision".utf8).write(to: directory.appendingPathComponent("newer.utf8"))
        try JSONSerialization.data(withJSONObject: metadata).write(to: directory.appendingPathComponent("a-duplicate.json"))
        let recovered = try DocumentRecoveryStore(rootURL: root).startSession()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.text, "newer revision")

        let nextEnumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let activeMetadata = try XCTUnwrap(nextEnumerator.allObjects.compactMap { $0 as? URL }.first {
            $0.lastPathComponent == "\(id.uuidString.lowercased()).json"
        })
        var newest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: activeMetadata)) as? [String: Any])
        newest["capturedAt"] = try XCTUnwrap(newest["capturedAt"] as? Double) + 60
        newest["revision"] = 0
        newest["contentFileName"] = "latest.utf8"
        let activeDirectory = activeMetadata.deletingLastPathComponent()
        try Data("newest timestamp".utf8).write(to: activeDirectory.appendingPathComponent("latest.utf8"))
        try JSONSerialization.data(withJSONObject: newest).write(to: activeDirectory.appendingPathComponent("z-duplicate.json"))
        let newestRecovery = try DocumentRecoveryStore(rootURL: root).startSession()
        XCTAssertEqual(newestRecovery.count, 1)
        XCTAssertEqual(newestRecovery.first?.text, "newest timestamp")
        XCTAssertEqual(newestRecovery.first?.revision, 0)
    }

    private func workspaceSnapshot(ids: [UUID]) -> WorkspaceSessionSnapshot {
        WorkspaceSessionSnapshot(windows: [WorkspaceWindowSnapshot(
            documents: ids.map { id in
                WorkspaceDocumentSnapshot(
                    documentID: id, text: "draft \(id)", sourceURL: nil,
                    language: .plainText, encoding: .utf8, isDirty: true,
                    selectionRange: NSRange(location: 0, length: 0),
                    scrollPositionRatio: 0, isPreviewVisible: false, fileRevisionSnapshot: nil
                )
            }, selectedDocumentID: ids.first, isSidebarVisible: true, frame: nil
        )])
    }

    private func workspaceContentURL(root: URL, id: UUID) throws -> URL {
        let directory = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("Workspace-") })
        return directory.appendingPathComponent("\(id.uuidString.lowercased()).utf8")
    }

    private func preservedContentURL(root: URL, id: UUID) throws -> URL {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root.appendingPathComponent("Preserved"), includingPropertiesForKeys: nil
        ))
        return try XCTUnwrap(enumerator.allObjects.compactMap { $0 as? URL }.first {
            $0.lastPathComponent == "\(id.uuidString.lowercased()).utf8"
        })
    }

    func testAbnormalSessionRestoresLatestAtomicSnapshot() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("draft.md")
        try Data("disk version".utf8).write(to: sourceURL)
        let baseline = try FileRevisionSnapshot.capture(sourceURL)
        let documentID = UUID()

        let interruptedStore = DocumentRecoveryStore(rootURL: directory.appendingPathComponent("Recovery"))
        XCTAssertTrue(try interruptedStore.startSession().isEmpty)
        interruptedStore.persist(makeSnapshot(
            documentID: documentID,
            text: "first recovery",
            revision: 1,
            sourceURL: sourceURL,
            baseline: baseline
        ))
        interruptedStore.persist(makeSnapshot(
            documentID: documentID,
            text: "latest recovery",
            revision: 2,
            sourceURL: sourceURL,
            baseline: baseline
        ))
        interruptedStore.flushForTesting()

        let relaunchedStore = DocumentRecoveryStore(rootURL: directory.appendingPathComponent("Recovery"))
        let recovered = try relaunchedStore.startSession()
        let snapshot = try XCTUnwrap(recovered.first)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(snapshot.documentID, documentID)
        XCTAssertEqual(snapshot.text, "latest recovery")
        XCTAssertEqual(snapshot.revision, 2)
        XCTAssertEqual(snapshot.sourceURL, sourceURL)
        XCTAssertEqual(snapshot.fileRevisionSnapshot, baseline)
        relaunchedStore.finishCleanlyForTesting()
    }

    func testCleanTerminationDoesNotOfferRecovery() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryURL = directory.appendingPathComponent("Recovery")
        let store = DocumentRecoveryStore(rootURL: recoveryURL)
        _ = try store.startSession()
        store.persist(makeSnapshot(text: "temporary", revision: 1))
        store.flushForTesting()
        store.finishCleanlyForTesting()

        let nextLaunch = DocumentRecoveryStore(rootURL: recoveryURL)
        XCTAssertTrue(try nextLaunch.startSession().isEmpty)
        nextLaunch.finishCleanlyForTesting()
    }

    func testDiscardRemovesOnlyTargetDocument() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryURL = directory.appendingPathComponent("Recovery")
        let store = DocumentRecoveryStore(rootURL: recoveryURL)
        _ = try store.startSession()
        let discardedID = UUID()
        let retainedID = UUID()
        store.persist(makeSnapshot(documentID: discardedID, text: "discard", revision: 1))
        store.persist(makeSnapshot(documentID: retainedID, text: "retain", revision: 1))
        store.discard(documentID: discardedID)
        store.flushForTesting()

        let nextLaunch = DocumentRecoveryStore(rootURL: recoveryURL)
        let recovered = try nextLaunch.startSession()
        XCTAssertEqual(recovered.map(\.documentID), [retainedID])
        nextLaunch.finishCleanlyForTesting()
    }

    @MainActor
    func testWindowManagerBuildsDirtyDocumentThatRequiresExplicitSave() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryURL = directory.appendingPathComponent("Recovery")
        let interruptedStore = DocumentRecoveryStore(rootURL: recoveryURL)
        _ = try interruptedStore.startSession()
        let documentID = UUID()
        interruptedStore.persist(makeSnapshot(
            documentID: documentID,
            text: "unsaved text",
            revision: 7
        ))
        interruptedStore.flushForTesting()

        let relaunchedStore = DocumentRecoveryStore(rootURL: recoveryURL)
        let manager = WindowManager(recoveryStore: relaunchedStore)
        let document = try XCTUnwrap(manager.takeRecoveredDocuments().first)
        XCTAssertEqual(document.id, documentID)
        XCTAssertEqual(document.text, "unsaved text")
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.statusMessage, "已从上次异常退出中恢复，请确认后保存")

        document.refreshDirtyState()
        XCTAssertTrue(document.isDirty)
        document.markSaved()
        XCTAssertFalse(document.isDirty)
        relaunchedStore.finishCleanlyForTesting()
    }

    @MainActor
    func testAppStatePersistsDirtyDocumentWhenAppResignsActive() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryURL = directory.appendingPathComponent("Recovery")
        let interruptedStore = DocumentRecoveryStore(rootURL: recoveryURL)
        _ = try interruptedStore.startSession()
        let suiteName = "LacEditorRecoveryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(
            recentFiles: RecentFilesStore(),
            preferences: AppPreferences(defaults: defaults),
            recoveryStore: interruptedStore
        )
        let document = try XCTUnwrap(state.selectedDocument)
        document.text = "typed immediately before losing focus"
        document.refreshDirtyState()
        state.persistRecoverySnapshotsImmediately()
        try await Task.sleep(for: .milliseconds(50))
        interruptedStore.flushForTesting()

        let relaunchedStore = DocumentRecoveryStore(rootURL: recoveryURL)
        let recovered = try relaunchedStore.startSession()
        XCTAssertEqual(recovered.first?.documentID, document.id)
        XCTAssertEqual(recovered.first?.text, "typed immediately before losing focus")
        relaunchedStore.finishCleanlyForTesting()
    }

    private func makeSnapshot(
        documentID: UUID = UUID(),
        text: String,
        revision: UInt,
        sourceURL: URL? = nil,
        baseline: FileRevisionSnapshot? = nil
    ) -> DocumentRecoverySnapshot {
        DocumentRecoverySnapshot(
            documentID: documentID,
            text: text,
            sourceURL: sourceURL,
            language: .markdown,
            encoding: .utf8,
            revision: revision,
            selectionRange: NSRange(location: 2, length: 3),
            scrollPositionRatio: 0.4,
            isPreviewVisible: true,
            fileRevisionSnapshot: baseline,
            capturedAt: Date()
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LacEditorRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
