import AppKit
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("Performance verification failed: \(message)")
    }
}

private func measure<T>(_ operation: () -> T) -> (value: T, seconds: Double) {
    let start = ProcessInfo.processInfo.systemUptime
    let value = operation()
    return (value, ProcessInfo.processInfo.systemUptime - start)
}

@main
struct PerformanceVerification {
    static func main() {
        require(
            DocumentPerformanceProfile.resolve(byteCount: 20 * 1_024 * 1_024) == .standard,
            "20 MB boundary remains standard without a large line count"
        )
        require(
            DocumentPerformanceProfile.resolve(byteCount: 20 * 1_024 * 1_024 + 1) == .large,
            "files over 20 MB enter large mode"
        )
        require(
            DocumentPerformanceProfile.resolve(byteCount: 50 * 1_024 * 1_024 + 1) == .extreme,
            "files over 50 MB enter extreme mode"
        )
        let largeProfileDocument = EditorDocument(
            text: "# Markdown",
            language: .markdown,
            performanceProfile: .large
        )
        require(!largeProfileDocument.isPreviewEffectivelyEnabled, "large mode disables preview")
        require(!largeProfileDocument.isWordCountEnabled, "large mode disables live word count")
        require(!largeProfileDocument.effectiveWordWrap(globalDefault: true), "large mode disables wrapping")
        largeProfileDocument.setOverride(true, for: .wordWrap)
        require(
            largeProfileDocument.effectiveWordWrap(globalDefault: false),
            "large-file feature override is document-local"
        )

        let line = "const value = 12345; // LacEditor performance baseline\n"
        let source = String(repeating: line, count: 80_000)
        let sourceLength = (source as NSString).length
        require(source.utf8.count >= 4_000_000, "fixture must be at least 4 MB")

        let indexResult = measure { LogicalLineIndex(text: source) }
        let finalPosition = indexResult.value.position(
            at: sourceLength,
            in: source as NSString
        )
        require(finalPosition.line == 80_001, "large-file line index result")
        require(indexResult.seconds < 5, "line index took \(indexResult.seconds)s")

        let searchResult = measure {
            TextSearchService.nextRange(
                in: source,
                query: "performance baseline",
                after: NSRange(location: sourceLength / 2, length: 0),
                caseSensitive: true
            )
        }
        require(searchResult.value != nil, "large-file search result")
        require(searchResult.seconds < 3, "large-file search took \(searchResult.seconds)s")

        let visibleStart = sourceLength / 2
        let highlightResult = measure {
            SyntaxHighlighter.tokens(
                in: source,
                language: .javascript,
                range: NSRange(location: visibleStart, length: 12_000)
            )
        }
        require(!highlightResult.value.isEmpty, "visible-range syntax tokens")
        require(highlightResult.seconds < 3, "visible-range highlighting took \(highlightResult.seconds)s")

        let attributeStorage = NSTextStorage(string: source)
        let attributeRange = NSRange(location: visibleStart, length: 12_000)
        let attributeResult = measure {
            SyntaxHighlighter.apply(
                tokens: highlightResult.value,
                to: attributeStorage,
                baseFont: NSFont.monospacedSystemFont(
                    ofSize: 14,
                    weight: .regular
                ),
                range: attributeRange
            )
        }
        require(attributeResult.seconds < 3, "visible attributes took \(attributeResult.seconds)s")
        require(
            attributeStorage.attribute(
                .foregroundColor,
                at: visibleStart,
                effectiveRange: nil
            ) != nil,
            "visible attributes were applied"
        )

        let layoutStorage = NSTextStorage(string: source)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: NSSize(
            width: 900,
            height: CGFloat.greatestFiniteMagnitude
        ))
        layoutStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        let initialLayoutResult = measure {
            layoutManager.ensureLayout(
                forBoundingRect: NSRect(x: 0, y: 0, width: 900, height: 800),
                in: textContainer
            )
        }
        require(
            initialLayoutResult.seconds < 3,
            "initial TextKit layout took \(initialLayoutResult.seconds)s"
        )
        let middleLayoutResult = measure {
            layoutManager.ensureLayout(forCharacterRange: NSRange(
                location: sourceLength / 2,
                length: 1
            ))
        }
        require(
            middleLayoutResult.seconds < 5,
            "middle TextKit layout took \(middleLayoutResult.seconds)s"
        )

        let extendedSource = String(repeating: line, count: 200_000)
        require(extendedSource.utf8.count >= 10_000_000, "extended fixture must be at least 10 MB")
        let extendedLength = (extendedSource as NSString).length
        let incrementalContext = SyntaxHighlighter.IncrementalContext()
        let extendedHighlightResult = measure {
            SyntaxHighlighter.tokens(
                in: extendedSource,
                language: .javascript,
                range: NSRange(location: extendedLength / 2, length: 32_000),
                context: incrementalContext,
                revision: 0
            )
        }
        require(!extendedHighlightResult.value.isEmpty, "10 MB visible-range syntax tokens")
        require(
            extendedHighlightResult.seconds < 3,
            "10 MB visible-range highlighting took \(extendedHighlightResult.seconds)s"
        )
        let cachedHighlightResult = measure {
            SyntaxHighlighter.tokens(
                in: extendedSource,
                language: .javascript,
                range: NSRange(
                    location: extendedLength / 2 + 8_000,
                    length: 32_000
                ),
                context: incrementalContext,
                revision: 0
            )
        }
        require(!cachedHighlightResult.value.isEmpty, "cached 10 MB syntax tokens")
        require(
            cachedHighlightResult.seconds < 1,
            "cached 10 MB highlighting took \(cachedHighlightResult.seconds)s"
        )

        let cancelledHighlightContext = SyntaxHighlighter.IncrementalContext()
        var cancellationChecks = 0
        _ = SyntaxHighlighter.tokens(
            in: extendedSource,
            language: .javascript,
            range: NSRange(location: extendedLength * 9 / 10, length: 32_000),
            context: cancelledHighlightContext,
            revision: 0,
            isCancelled: {
                cancellationChecks += 1
                return cancellationChecks >= 12
            }
        )
        let firstCancelledCheckpoint = cancelledHighlightContext.preparedThrough
        require(
            firstCancelledCheckpoint > 0,
            "cancelled highlighting must retain completed lexical checkpoints"
        )
        cancellationChecks = 0
        _ = SyntaxHighlighter.tokens(
            in: extendedSource,
            language: .javascript,
            range: NSRange(location: extendedLength * 9 / 10, length: 32_000),
            context: cancelledHighlightContext,
            revision: 0,
            isCancelled: {
                cancellationChecks += 1
                return cancellationChecks >= 12
            }
        )
        require(
            cancelledHighlightContext.preparedThrough > firstCancelledCheckpoint,
            "restarted highlighting must resume beyond the previous cancellation point"
        )

        let viewportStorage = NSTextStorage(string: extendedSource)
        let viewportLayoutManager = NSLayoutManager()
        EditorLayoutPolicy.configure(
            viewportLayoutManager,
            textLength: extendedLength
        )
        let viewportContainer = NSTextContainer(containerSize: NSSize(
            width: 900,
            height: CGFloat.greatestFiniteMagnitude
        ))
        viewportContainer.widthTracksTextView = false
        viewportStorage.addLayoutManager(viewportLayoutManager)
        viewportLayoutManager.addTextContainer(viewportContainer)
        require(
            viewportLayoutManager.allowsNonContiguousLayout,
            "editor layout policy must use non-contiguous layout"
        )
        require(
            !viewportLayoutManager.backgroundLayoutEnabled,
            "editor layout policy must not trigger full-document background layout"
        )
        let smallLayoutManager = NSLayoutManager()
        EditorLayoutPolicy.configure(smallLayoutManager, textLength: 10_000)
        require(
            smallLayoutManager.allowsNonContiguousLayout
                && smallLayoutManager.backgroundLayoutEnabled,
            "small documents must retain background layout while allowing viewport jumps"
        )
        var deepLayoutDurations: [Double] = []
        for percentage in [10, 50, 90] {
            let result = measure {
                viewportLayoutManager.ensureLayout(forCharacterRange: NSRange(
                    location: extendedLength * percentage / 100,
                    length: 1
                ))
            }
            deepLayoutDurations.append(result.seconds)
        }
        require(
            deepLayoutDurations.max() ?? .infinity < 1,
            "viewport layout became position-dependent: \(deepLayoutDurations)"
        )
        let resizeLayoutResult = measure {
            for width in stride(from: 890.0, through: 710.0, by: -10.0) {
                viewportContainer.containerSize.width = width
                viewportLayoutManager.ensureLayout(forCharacterRange: NSRange(
                    location: extendedLength * 9 / 10,
                    length: 1
                ))
            }
        }
        require(
            resizeLayoutResult.seconds < 1,
            "deep viewport layout after repeated width changes took \(resizeLayoutResult.seconds)s"
        )

        let extendedLineIndex = LogicalLineIndex(text: extendedSource)
        let mutableExtendedSource = NSMutableString(string: extendedSource)
        let indexedPositionResult = measure {
            var checksum = 0
            for sample in 0..<10_000 {
                let location = (sample * 997) % extendedLength
                let position = extendedLineIndex.position(
                    at: location,
                    in: mutableExtendedSource
                )
                checksum &+= position.line &+ position.column
            }
            return checksum
        }
        require(indexedPositionResult.value > 0, "indexed position checksum")
        require(
            indexedPositionResult.seconds < 1,
            "10,000 mutable-storage line lookups took \(indexedPositionResult.seconds)s"
        )

        let distantMarkdown = String(repeating: "ordinary paragraph\n", count: 200_000)
            + "7. first\n99. second\n100. third\n"
        let listLocation = (distantMarkdown as NSString).length - 12
        let listResult = measure {
            ListContinuationService.normalizeOrderedList(
                in: distantMarkdown,
                aroundUTF16Location: listLocation
            )
        }
        require(
            listResult.value?.text.hasSuffix("7. first\n8. second\n9. third\n") == true,
            "localized ordered-list normalization result"
        )
        require(
            listResult.seconds < 0.25,
            "localized list normalization took \(listResult.seconds)s"
        )

        let liveDocument = EditorDocument()
        let liveProviderID = UUID()
        var liveText = extendedSource
        liveDocument.attachLiveTextProvider(
            id: liveProviderID,
            provider: { liveText },
            acknowledgement: { _ in }
        )
        let liveEditResult = measure {
            for _ in 0..<10_000 {
                liveDocument.noteLiveEdit(isEmpty: false)
            }
        }
        require(
            liveDocument.text.isEmpty,
            "live edits must not copy the large editor snapshot per keystroke"
        )
        require(
            liveEditResult.seconds < 1,
            "10,000 live edit notifications took \(liveEditResult.seconds)s"
        )
        let modelSyncResult = measure {
            require(liveDocument.synchronizeLiveText(), "large live snapshot synchronization")
        }
        require(
            liveDocument.text.utf8.count == extendedSource.utf8.count,
            "large live snapshot content length"
        )
        require(
            modelSyncResult.seconds < 2,
            "large model synchronization took \(modelSyncResult.seconds)s"
        )
        liveText = ""
        liveDocument.detachLiveTextProvider(id: liveProviderID)

        print(String(
            format: "Performance verification passed: index %.3fs, search %.3fs, highlight %.3fs, attributes %.3fs, TextKit first %.3fs/middle %.3fs, 10 MB initial %.3fs/cached %.3fs, deep layout %.3fs/resize %.3fs, 10k positions %.3fs, 10k edits %.3fs/model sync %.3fs",
            indexResult.seconds,
            searchResult.seconds,
            highlightResult.seconds,
            attributeResult.seconds,
            initialLayoutResult.seconds,
            middleLayoutResult.seconds,
            extendedHighlightResult.seconds,
            cachedHighlightResult.seconds,
            deepLayoutDurations.max() ?? 0,
            resizeLayoutResult.seconds,
            indexedPositionResult.seconds,
            liveEditResult.seconds,
            modelSyncResult.seconds
        ))
    }
}
