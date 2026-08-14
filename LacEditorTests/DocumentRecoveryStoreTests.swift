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
        XCTAssertEqual(try store.loadAndConsume(), snapshot)
        XCTAssertNil(try store.loadAndConsume())
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
