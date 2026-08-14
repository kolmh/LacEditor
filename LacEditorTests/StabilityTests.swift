import Foundation
import XCTest
@testable import LacEditor

final class StabilityTests: XCTestCase {
    func testJSONFormattingPreservesObjectOrderAndLexemes() throws {
        let source = #"{"z":1,"a":2,"z":3,"nested":{"b":true,"a":null},"number":1.2300e+04,"escaped":"a\\/b\\u4F60"}"#
        let pretty = try JSONFormatter.format(source, pretty: true)
        let compact = try JSONFormatter.format(source, pretty: false)

        XCTAssertLessThan(
            try XCTUnwrap(pretty.range(of: #""z" : 1"#)?.lowerBound),
            try XCTUnwrap(pretty.range(of: #""a" : 2"#)?.lowerBound)
        )
        XCTAssertEqual(pretty.components(separatedBy: #""z" :"#).count, 3)
        XCTAssertTrue(pretty.contains("1.2300e+04"))
        XCTAssertTrue(pretty.contains(#""escaped" : "a\\/b\\u4F60""#))
        XCTAssertEqual(compact, source)
        XCTAssertNoThrow(
            try JSONSerialization.jsonObject(with: Data(pretty.utf8))
        )
    }

    func testJSONFormattingRejectsInvalidTokensAndSupportsCancellation() throws {
        for source in [
            #"{"a":01}"#,
            #"{"a":1,}"#,
            #"[1,]"#,
            #"{"a":"\x"}"#,
            #"true false"#
        ] {
            XCTAssertThrowsError(try JSONFormatter.format(source, pretty: true), source)
        }

        XCTAssertThrowsError(
            try JSONFormatter.format(
                String(repeating: " ", count: 8_192) + "null",
                pretty: false,
                isCancelled: { true }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testLineNumberGeometryTracksScrollAndLineCenter() {
        let textLine = NSRect(x: 0, y: 240, width: 500, height: 24)
        let contentLayout = NSRect(x: 0, y: 72, width: 44, height: 600)
        let rulerBounds = NSRect(x: 0, y: 0, width: 44, height: 672)
        let initial = LineNumberGeometry.rulerRect(
            for: textLine,
            visibleTextRect: NSRect(x: 0, y: 200, width: 800, height: 600),
            contentLayoutRect: contentLayout,
            rulerBounds: rulerBounds
        )
        let scrolled = LineNumberGeometry.rulerRect(
            for: textLine,
            visibleTextRect: NSRect(x: 0, y: 209, width: 800, height: 600),
            contentLayoutRect: contentLayout,
            rulerBounds: rulerBounds
        )
        XCTAssertEqual(initial.minY, 112, accuracy: 0.001)
        XCTAssertEqual(scrolled.minY, initial.minY - 9, accuracy: 0.001)

        let origin = LineNumberGeometry.labelOrigin(
            rulerWidth: 44,
            labelSize: NSSize(width: 12, height: 14),
            lineRect: NSRect(x: 0, y: 112, width: 44, height: 24)
        )
        XCTAssertEqual(origin.x, 16, accuracy: 0.001)
        XCTAssertEqual(origin.y, 117, accuracy: 0.001)
    }

    func testLineNumberSelectionIncludesCompleteLogicalLines() {
        let first = NSRange(location: 12, length: 8)
        let second = NSRange(location: 32, length: 14)
        XCTAssertEqual(
            LineNumberGeometry.selectionRange(from: first, to: second),
            NSRange(location: 12, length: 34)
        )
        XCTAssertEqual(
            LineNumberGeometry.selectionRange(from: second, to: first),
            NSRange(location: 12, length: 34)
        )
    }

    func testLineNumberVisibleMapCacheKeyTracksLayoutInputs() {
        let base = LineNumberVisibleMapCacheKey(
            visibleTextRect: NSRect(x: 0, y: 120, width: 700, height: 500),
            contentLayoutRect: NSRect(x: 0, y: 52, width: 44, height: 500),
            rulerBounds: NSRect(x: 0, y: 0, width: 44, height: 552),
            textContainerWidth: 656,
            textLength: 12_000,
            layoutGeneration: 7,
            foldedRange: nil
        )
        XCTAssertEqual(base, base)

        let resized = LineNumberVisibleMapCacheKey(
            visibleTextRect: NSRect(x: 0, y: 120, width: 720, height: 500),
            contentLayoutRect: base.contentLayoutRect,
            rulerBounds: base.rulerBounds,
            textContainerWidth: 676,
            textLength: base.textLength,
            layoutGeneration: base.layoutGeneration,
            foldedRange: nil
        )
        XCTAssertNotEqual(base, resized)

        let invalidated = LineNumberVisibleMapCacheKey(
            visibleTextRect: base.visibleTextRect,
            contentLayoutRect: base.contentLayoutRect,
            rulerBounds: base.rulerBounds,
            textContainerWidth: base.textContainerWidth,
            textLength: base.textLength,
            layoutGeneration: base.layoutGeneration + 1,
            foldedRange: nil
        )
        XCTAssertNotEqual(base, invalidated)
    }

    @MainActor
    func testSidebarLibraryPersistsGroupsFavoritesAndOrdering() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("sidebar.json")
        let firstURL = directory.appendingPathComponent("first.md")
        let secondURL = directory.appendingPathComponent("second.json")
        try Data("# first".utf8).write(to: firstURL)
        try Data("{}".utf8).write(to: secondURL)

        let store = SidebarLibraryStore(storageURL: storage)
        store.toggleFavorite(firstURL)
        store.toggleFavorite(secondURL)
        store.moveFavorite(secondURL, before: firstURL)
        let workID = try XCTUnwrap(store.createGroup(named: "工作"))
        let duplicateID = try XCTUnwrap(store.createGroup(named: "工作"))
        store.add(firstURL, toGroup: workID)
        store.add(secondURL, toGroup: workID)
        store.moveFile(secondURL, inGroup: workID, before: firstURL)
        store.setExpanded(false, for: workID)
        store.setExpanded(false, for: .favorites)
        store.setExpanded(false, for: .groups)
        store.setExpanded(false, for: .recent)

        let restored = SidebarLibraryStore(storageURL: storage)
        XCTAssertEqual(restored.favoriteURLs.map(\.lastPathComponent), ["second.json", "first.md"])
        XCTAssertEqual(restored.groups.map(\.name), ["工作", "工作 2"])
        XCTAssertEqual(restored.groups.first?.urls.map(\.lastPathComponent), ["second.json", "first.md"])
        XCTAssertEqual(restored.groups.first?.isExpanded, false)
        XCTAssertFalse(restored.favoriteSectionExpanded)
        XCTAssertFalse(restored.groupsSectionExpanded)
        XCTAssertFalse(restored.recentSectionExpanded)

        restored.deleteGroup(duplicateID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
    }

    @MainActor
    func testSidebarLibraryMigratesRenamedPaths() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SidebarLibraryStore(
            storageURL: directory.appendingPathComponent("sidebar.json")
        )
        let oldURL = directory.appendingPathComponent("old.txt")
        let newURL = directory.appendingPathComponent("new.txt")
        store.toggleFavorite(oldURL)
        let groupID = try XCTUnwrap(store.createGroup(named: "临时"))
        store.add(oldURL, toGroup: groupID)

        store.replace(oldURL, with: newURL)
        XCTAssertEqual(store.favoriteURLs, [newURL])
        XCTAssertEqual(store.groups.first?.urls, [newURL])
    }

    @MainActor
    func testPreferencesAreSharedAcrossWindowsAndPersistWordWrap() {
        let suiteName = "LacEditorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        let first = AppState(
            recentFiles: RecentFilesStore(),
            preferences: preferences
        )
        let second = AppState(
            recentFiles: RecentFilesStore(),
            preferences: preferences
        )

        first.isWordWrapEnabled = false
        first.editorFontSize = 18
        first.editorLineSpacing = 7
        first.workspaceExitBehavior = .askToSave
        first.theme = .dark
        XCTAssertFalse(second.isWordWrapEnabled)
        XCTAssertEqual(second.editorFontSize, 18)
        XCTAssertEqual(second.editorLineSpacing, 7)
        XCTAssertEqual(second.workspaceExitBehavior, .askToSave)
        XCTAssertEqual(second.theme, .dark)

        first.resetLineSpacing()
        XCTAssertEqual(first.editorLineSpacing, AppPreferences.defaultLineSpacing)
        XCTAssertEqual(second.editorLineSpacing, AppPreferences.defaultLineSpacing)
        first.editorLineSpacing = 7

        let restored = AppPreferences(defaults: defaults)
        XCTAssertFalse(restored.wordWrapEnabled)
        XCTAssertEqual(restored.editorFontSize, 18)
        XCTAssertEqual(restored.editorLineSpacing, 7)
        XCTAssertEqual(restored.workspaceExitBehavior, .askToSave)
        XCTAssertEqual(restored.theme, .dark)
    }

    func testFileIdentityResolvesSymbolicLinks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("original.txt")
        let link = directory.appendingPathComponent("alias.txt")
        try Data("内容".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        XCTAssertTrue(
            DocumentFileIdentity.resolve(file).matches(
                DocumentFileIdentity.resolve(link)
            )
        )
    }

    func testUTF16RoundTripPreservesEncoding() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("laceditor-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = "中文与 emoji 😀"
        try FileService.write(
            source,
            to: url,
            encoding: .utf16LittleEndian,
            encodingName: "UTF-16 LE"
        )
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data, encoding: .utf16LittleEndian), source)
    }

    func testGB18030RoundTripPreservesEncoding() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("laceditor-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = "简体中文往返保存"
        try FileService.write(
            source,
            to: url,
            encoding: FileService.gb18030Encoding,
            encodingName: "简体中文（GB 18030）"
        )
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data, encoding: FileService.gb18030Encoding), source)
    }

    func testLossySaveIsRejected() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("laceditor-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(
            try FileService.write(
                "无法用 ASCII 保存：中",
                to: url,
                encoding: .ascii,
                encodingName: "ASCII"
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCodecLimitsAndPercentEncoding() throws {
        XCTAssertEqual(TextCodecService.warningInputByteLimit, 8 * 1_024 * 1_024)
        XCTAssertEqual(TextCodecService.maximumInputByteLimit, 32 * 1_024 * 1_024)
        XCTAssertEqual(
            try TextCodecService.transform("中 文", operation: .urlEncodeComponent),
            "%E4%B8%AD%20%E6%96%87"
        )
    }

    func testLexersHandleEmojiSurrogateCodeUnits() {
        let sources: [(String, EditorLanguage)] = [
            ("let emoji = 😀 // comment\nlet value = 1", .javascript),
            ("{\"emoji\": \"😀\", \"ok\": true}", .json),
            ("value = 😀 # comment\nprint(value)", .python),
            ("echo 😀 # comment\nprintf ok", .shell)
        ]
        for (source, language) in sources {
            _ = SyntaxHighlighter.tokens(
                in: source,
                language: language,
                range: NSRange(location: 0, length: (source as NSString).length)
            )
        }
    }


    @MainActor
    func testTransformationControllerReleasesAppStateAfterDispose() {
        var state: AppState? = AppState(
            recentFiles: RecentFilesStore(),
            preferences: AppPreferences()
        )
        weak let weakState = state
        autoreleasepool {
            var controller: TextTransformationWindowController? = state.map {
                TextTransformationWindowController(appState: $0)
            }
            controller?.dispose()
            controller = nil
        }
        state = nil
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertNil(weakState)
    }
}
