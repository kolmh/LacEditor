import Foundation
import XCTest
@testable import LacEditor

final class StabilityTests: XCTestCase {
    func testDirtyRangeAccumulatorTranslatesEditsInUTF16Coordinates() {
        let id = UUID()
        var accumulator = DirtyRangeAccumulator()
        accumulator.invalidate(NSRange(location: 10, length: 5))
        accumulator.append(DocumentEditDelta(
            documentID: id,
            revision: 1,
            editedRange: NSRange(location: 20, length: 0),
            replacementLength: 3,
            changeInLength: 3,
            changedLineRange: nil
        ))
        XCTAssertEqual(
            accumulator.ranges,
            [NSRange(location: 10, length: 5), NSRange(location: 20, length: 3)]
        )

        accumulator.append(DocumentEditDelta(
            documentID: id,
            revision: 2,
            editedRange: NSRange(location: 12, length: 2),
            replacementLength: 0,
            changeInLength: -2,
            changedLineRange: nil
        ))
        XCTAssertEqual(
            accumulator.ranges,
            [NSRange(location: 10, length: 5), NSRange(location: 18, length: 3)]
        )
    }

    func testDirtyRangeAccumulatorMergesAdjacentAndZeroLengthEdits() {
        var accumulator = DirtyRangeAccumulator()
        accumulator.invalidate(NSRange(location: 4, length: 2))
        accumulator.append(DocumentEditDelta(
            documentID: UUID(),
            revision: 1,
            editedRange: NSRange(location: 6, length: 0),
            replacementLength: 0,
            changeInLength: 0,
            changedLineRange: nil
        ))
        XCTAssertEqual(accumulator.ranges, [NSRange(location: 4, length: 2)])

        accumulator.append(DocumentEditDelta(
            documentID: UUID(),
            revision: 2,
            editedRange: NSRange(location: 5, length: 0),
            replacementLength: 2,
            changeInLength: 2,
            changedLineRange: nil
        ))
        XCTAssertEqual(accumulator.ranges, [NSRange(location: 4, length: 3)])
    }

    func testDirtyRangeAccumulatorUsesUTF16OffsetsForEmojiAndChineseText() {
        let text = "中文😀后续"
        let nsText = text as NSString
        XCTAssertEqual(nsText.length, 6)
        var accumulator = DirtyRangeAccumulator()
        accumulator.append(DocumentEditDelta(
            documentID: UUID(),
            revision: 1,
            editedRange: NSRange(location: 2, length: 2),
            replacementLength: 1,
            changeInLength: -1,
            changedLineRange: nil
        ))
        accumulator.append(DocumentEditDelta(
            documentID: UUID(),
            revision: 2,
            editedRange: NSRange(location: 3, length: 0),
            replacementLength: 2,
            changeInLength: 2,
            changedLineRange: nil
        ))
        XCTAssertEqual(accumulator.unionRange, NSRange(location: 2, length: 3))
    }

    @MainActor
    func testEditorLayoutKeepsMixedScriptLinesAndTrailingLineStable() throws {
        let font = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
        let text = "abc中文\n中文abc\n# 标题 123\n"
        let storage = NSTextStorage(
            string: text,
            attributes: [.font: font]
        )
        let layoutManager = FoldLayoutManager()
        layoutManager.textFont = font
        layoutManager.editorLineSpacing = 6
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)

        var fragmentHeights: [CGFloat] = []
        var usedHeights: [CGFloat] = []
        var baselineLocations: [CGFloat] = []
        let glyphRange = layoutManager.glyphRange(
            for: container
        )
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            fragmentRect,
            usedRect,
            _,
            glyphRange,
            _ in
            fragmentHeights.append(fragmentRect.height)
            usedHeights.append(usedRect.height)
            if glyphRange.length > 0 {
                baselineLocations.append(
                    layoutManager.location(forGlyphAt: glyphRange.location).y
                )
            }
        }

        XCTAssertGreaterThanOrEqual(fragmentHeights.count, 3)
        for height in fragmentHeights {
            XCTAssertEqual(height, layoutManager.editorLineHeight, accuracy: 0.001)
        }
        for height in usedHeights {
            XCTAssertEqual(height, layoutManager.editorLineHeight, accuracy: 0.001)
        }
        for baseline in baselineLocations.dropFirst() {
            XCTAssertEqual(baseline, baselineLocations[0], accuracy: 0.001)
        }
        XCTAssertEqual(
            layoutManager.extraLineFragmentRect.height,
            layoutManager.editorLineHeight,
            accuracy: 0.001
        )
    }

    @MainActor
    func testSyntaxHighlightUsesTemporaryColorsWithoutChangingTextMetrics() throws {
        let font = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = 32
        let storage = NSTextStorage(
            string: "# 标题\n普通正文",
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
        let layoutManager = FoldLayoutManager()
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(NSTextContainer(
            containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        ))
        let fullRange = NSRange(location: 0, length: storage.length)
        let originalAttributes = storage.attributes(at: 0, effectiveRange: nil)

        SyntaxHighlighter.apply(
            tokens: [.init(range: NSRange(location: 0, length: 4), kind: .heading)],
            to: layoutManager,
            range: fullRange
        )

        XCTAssertEqual(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, font)
        XCTAssertEqual(
            storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
            paragraph
        )
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            originalAttributes[.foregroundColor] as? NSColor
        )
        XCTAssertNotNil(layoutManager.temporaryAttribute(
            .foregroundColor,
            atCharacterIndex: 0,
            effectiveRange: nil
        ))
        XCTAssertNil(layoutManager.temporaryAttribute(
            .foregroundColor,
            atCharacterIndex: 5,
            effectiveRange: nil
        ))

        SyntaxHighlighter.apply(tokens: [], to: layoutManager, range: fullRange)
        XCTAssertNil(layoutManager.temporaryAttribute(
            .foregroundColor,
            atCharacterIndex: 0,
            effectiveRange: nil
        ))
        XCTAssertEqual(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, font)
    }

    func testMarkdownHeadingHighlightNeverLeaksIntoFollowingLines() {
        let markdown = "# 一级标题\n普通正文\n## 二级标题\n结尾"
        let nsMarkdown = markdown as NSString
        let tokens = SyntaxHighlighter.tokens(
            in: markdown,
            language: .markdown
        )
        let headings = tokens.filter { $0.kind == .heading }

        XCTAssertEqual(headings.count, 2)
        for heading in headings {
            let value = nsMarkdown.substring(with: heading.range)
            XCTAssertTrue(value.hasPrefix("#"))
            XCTAssertFalse(value.contains("\n"))
        }
        let ordinaryRange = nsMarkdown.range(of: "普通正文")
        XCTAssertFalse(tokens.contains {
            NSIntersectionRange($0.range, ordinaryRange).length > 0
        })
    }

    @MainActor
    func testMarkedChineseTextCannotReplaceRequestedFontOrMoveLine() throws {
        let font = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
        let storage = NSTextStorage()
        let layoutManager = FoldLayoutManager()
        layoutManager.textFont = font
        layoutManager.editorLineSpacing = 6
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(container)
        let textView = LacTextView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 200),
            textContainer: container
        )
        textView.font = font
        textView.editorLineSpacing = 6
        textView.configureTabStops()
        textView.string = "abc"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        layoutManager.ensureLayout(for: container)
        let initialRect = layoutManager.lineFragmentRect(
            forGlyphAt: 0,
            effectiveRange: nil
        )

        textView.setMarkedText(
            "中文",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        layoutManager.ensureLayout(for: container)
        let composingRect = layoutManager.lineFragmentRect(
            forGlyphAt: 0,
            effectiveRange: nil
        )

        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertEqual(textView.font, font)
        XCTAssertEqual(composingRect.height, initialRect.height, accuracy: 0.001)
        XCTAssertEqual(composingRect.minY, initialRect.minY, accuracy: 0.001)

        textView.unmarkText()
        layoutManager.ensureLayout(for: container)
        let committedRect = layoutManager.lineFragmentRect(
            forGlyphAt: 0,
            effectiveRange: nil
        )
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(textView.font, font)
        XCTAssertEqual(textView.typingAttributes[.font] as? NSFont, font)
        XCTAssertEqual(committedRect.height, initialRect.height, accuracy: 0.001)
        XCTAssertEqual(committedRect.minY, initialRect.minY, accuracy: 0.001)
    }

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

#if canImport(SwiftTreeSitter) && canImport(TreeSitterJavaScript)
    func testTreeSitterJavaScriptUsesUTF16RangesAndIncrementalEdits() {
        let documentID = UUID()
        let source = "const 中文 = \"😀\"; // 注释\nconst value = /[()]/;"
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        let first = SyntaxHighlighter.tokens(
            in: source,
            language: .javascript,
            range: fullRange,
            revision: 1,
            documentID: documentID
        )
        let comments = first.filter { $0.kind == .comment }
        let tokenDescription = first.map { "\($0.kind):\($0.range)" }.joined(separator: ",")
        XCTAssertEqual(comments.count, 1, "tokens=\(tokenDescription)")
        guard let comment = comments.first else { return }
        XCTAssertEqual((source as NSString).substring(with: comment.range), "// 注释")
        let strings = first.filter { $0.kind == .string }
        XCTAssertTrue(strings.contains {
            (source as NSString).substring(with: $0.range) == "\"😀\""
        })

        let oldValueRange = (source as NSString).range(of: "value")
        let updated = (source as NSString).replacingCharacters(
            in: oldValueRange,
            with: "nextValue"
        )
        let edit = DocumentEditDelta(
            documentID: documentID,
            revision: 2,
            editedRange: oldValueRange,
            replacementLength: ("nextValue" as NSString).length,
            changeInLength: ("nextValue" as NSString).length - oldValueRange.length,
            changedLineRange: nil
        )
        let second = SyntaxHighlighter.tokens(
            in: updated,
            language: .javascript,
            range: NSRange(location: 0, length: (updated as NSString).length),
            revision: 2,
            documentID: documentID,
            edit: edit
        )
        XCTAssertEqual(
            second.filter { $0.kind == .comment }.map {
                (updated as NSString).substring(with: $0.range)
            },
            ["// 注释"]
        )
        XCTAssertTrue(second.contains {
            $0.kind == .variable
                && (updated as NSString).substring(with: $0.range) == "nextValue"
        })
    }

#if canImport(TreeSitterTypeScript)
    func testTreeSitterTypeScriptHandlesTypesAndUnicodeComments() {
        let source = "interface 用户 { value: string }\nconst value: number = 1; // 注释"
        let tokens = SyntaxHighlighter.tokens(
            in: source,
            language: .typescript,
            range: NSRange(location: 0, length: (source as NSString).length),
            revision: 1,
            documentID: UUID()
        )
        let comments = tokens.filter { $0.kind == .comment }
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual((source as NSString).substring(with: comments[0].range), "// 注释")
        XCTAssertTrue(tokens.contains {
            $0.kind == .variable
                && (source as NSString).substring(with: $0.range) == "用户"
        })
        XCTAssertTrue(tokens.contains {
            $0.kind == .typeName
                && (source as NSString).substring(with: $0.range) == "string"
        })
    }
#endif
#if canImport(TreeSitterPython)
    func testTreeSitterPythonHandlesIndentationStringsAndUnicodeComments() {
        let documentID = UUID()
        let source = "def 处理(值: str):\n    return \"😀\" + 值  # 注释"
        let tokens = SyntaxHighlighter.tokens(
            in: source,
            language: .python,
            range: NSRange(location: 0, length: (source as NSString).length),
            revision: 1,
            documentID: documentID
        )
        let comments = tokens.filter { $0.kind == .comment }
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual((source as NSString).substring(with: comments[0].range), "# 注释")
        XCTAssertTrue(tokens.contains {
            $0.kind == .string
                && (source as NSString).substring(with: $0.range) == "\"😀\""
        })
        XCTAssertTrue(tokens.contains {
            $0.kind == .variable
                && (source as NSString).substring(with: $0.range) == "处理"
        })

        let oldRange = (source as NSString).range(of: "值")
        let replacementLength = ("输入" as NSString).length
        let updated = (source as NSString).replacingCharacters(
            in: oldRange,
            with: "输入"
        )
        let edit = DocumentEditDelta(
            documentID: documentID,
            revision: 2,
            editedRange: oldRange,
            replacementLength: replacementLength,
            changeInLength: replacementLength - oldRange.length,
            changedLineRange: nil
        )
        let incrementallyUpdated = SyntaxHighlighter.tokens(
            in: updated,
            language: .python,
            range: NSRange(location: 0, length: (updated as NSString).length),
            revision: 2,
            documentID: documentID,
            edit: edit
        )
        XCTAssertTrue(incrementallyUpdated.contains {
            $0.kind == .variable
                && (updated as NSString).substring(with: $0.range) == "输入"
        })
    }
#endif
#if canImport(TreeSitterCSS)
    func testTreeSitterCSSHandlesSelectorsPropertiesAndComments() {
        let source = ".button:hover { color: #ff00aa; margin: 12px; } /* 注释 */"
        let tokens = SyntaxHighlighter.tokens(
            in: source,
            language: .css,
            range: NSRange(location: 0, length: (source as NSString).length),
            revision: 1,
            documentID: UUID()
        )
        guard let comment = tokens.first(where: { $0.kind == .comment }) else {
            XCTFail("missing CSS comment token")
            return
        }
        XCTAssertEqual((source as NSString).substring(with: comment.range), "/* 注释 */")
        let cssTokenDescription = tokens.map {
            "\($0.kind):\((source as NSString).substring(with: $0.range))"
        }.joined(separator: ",")
        XCTAssertTrue(tokens.contains {
            $0.kind == .property
                && (source as NSString).substring(with: $0.range) == "color"
        }, cssTokenDescription)
        XCTAssertTrue(tokens.contains {
            $0.kind == .number
                && (source as NSString).substring(with: $0.range) == "12px"
        }, cssTokenDescription)
    }
#endif
#if canImport(TreeSitterHTML)
    func testTreeSitterHTMLHandlesTagsAttributesCommentsAndUnicode() {
        let source = "<div class=\"box\">你好 <span data-x='1'>world</span><!-- 注释 --></div>"
        let tokens = SyntaxHighlighter.tokens(
            in: source,
            language: .html,
            range: NSRange(location: 0, length: (source as NSString).length),
            revision: 1,
            documentID: UUID()
        )
        guard let comment = tokens.first(where: { $0.kind == .comment }) else {
            XCTFail("missing HTML comment token")
            return
        }
        XCTAssertEqual((source as NSString).substring(with: comment.range), "<!-- 注释 -->")
        XCTAssertTrue(tokens.contains {
            $0.kind == .heading
                && (source as NSString).substring(with: $0.range) == "div"
        })
        XCTAssertTrue(tokens.contains {
            $0.kind == .attribute
                && (source as NSString).substring(with: $0.range) == "class"
        })
        XCTAssertTrue(tokens.contains {
            $0.kind == .string
                && (source as NSString).substring(with: $0.range) == "\"box\""
        })
    }
#endif
#endif
#if canImport(TreeSitterSwift) && canImport(TreeSitterBash) && canImport(TreeSitterYAML) && canImport(TreeSitterCPP) && canImport(TreeSitterSQL)
    func testTreeSitterGenericLanguagesHandleCommentsStringsAndUnicode() {
        let cases: [(String, EditorLanguage, String)] = [
            ("func 处理() { let value = 1; print(\"😀\") } // 注释", .swift, "// 注释"),
            ("function run() { echo \"😀\"; } # 注释", .shell, "# 注释"),
            ("标题: 你好\nitems:\n  - value: true # 注释", .yaml, "# 注释"),
            ("int main() { return 1; } // 注释", .cFamily, "// 注释"),
            ("SELECT name FROM users WHERE id = 1; -- 注释", .sql, "-- 注释")
        ]
        for (source, language, commentText) in cases {
            let tokens = SyntaxHighlighter.tokens(
                in: source,
                language: language,
                range: NSRange(location: 0, length: (source as NSString).length),
                revision: 1,
                documentID: UUID()
            )
            XCTAssertTrue(tokens.contains {
                $0.kind == .comment
                    && (source as NSString).substring(with: $0.range) == commentText
            }, "missing comment for \(language.rawValue)")
            XCTAssertFalse(tokens.isEmpty, "missing syntax tokens for \(language.rawValue)")
        }
    }
#endif


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
