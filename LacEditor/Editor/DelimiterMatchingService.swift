import Foundation

enum DelimiterMatchingService {
    struct Match: Equatable {
        let openingRange: NSRange
        let closingRange: NSRange
    }

    fileprivate struct Opening: Equatable {
        let location: Int
        let value: unichar
    }

    fileprivate struct Checkpoint {
        let location: Int
        let stack: [Opening]
    }

    fileprivate struct Preparation {
        let checkpoint: Checkpoint
        let generation: UInt
    }

    final class Context {
        fileprivate let lexicalContext = CodeLexicalScanner.IncrementalContext()
        private let lock = NSRecursiveLock()
        private var language: EditorLanguage?
        private var revision: UInt?
        private var checkpoints = [Checkpoint(location: 0, stack: [])]
        private var acceptsRevisionChange = false
        private var generation: UInt = 0

        func reset() {
            lock.lock()
            resetLocked()
            lock.unlock()
            lexicalContext.reset()
        }

        private func resetLocked() {
            generation &+= 1
            language = nil
            revision = nil
            checkpoints = [Checkpoint(location: 0, stack: [])]
            acceptsRevisionChange = false
        }

        func invalidate(after location: Int) {
            lock.lock()
            generation &+= 1
            checkpoints.removeAll { $0.location > max(0, location) }
            if checkpoints.isEmpty {
                checkpoints = [Checkpoint(location: 0, stack: [])]
            }
            acceptsRevisionChange = true
            lock.unlock()
            lexicalContext.invalidate(after: location)
        }

        fileprivate func prepare(
            language newLanguage: EditorLanguage,
            revision newRevision: UInt,
            location: Int
        ) -> Preparation {
            lock.lock()
            defer { lock.unlock() }
            if language != newLanguage {
                resetLocked()
                language = newLanguage
                revision = newRevision
            } else if revision != newRevision {
                if acceptsRevisionChange {
                    revision = newRevision
                    acceptsRevisionChange = false
                } else {
                    resetLocked()
                    language = newLanguage
                    revision = newRevision
                }
            }
            return Preparation(
                checkpoint: checkpoints.last(where: { $0.location <= location })
                    ?? Checkpoint(location: 0, stack: []),
                generation: generation
            )
        }

        fileprivate func commit(
            _ additions: [Checkpoint],
            language expectedLanguage: EditorLanguage,
            revision expectedRevision: UInt,
            generation expectedGeneration: UInt
        ) {
            guard !additions.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            guard language == expectedLanguage,
                  revision == expectedRevision,
                  generation == expectedGeneration else { return }
            var byLocation = Dictionary(
                uniqueKeysWithValues: checkpoints.map { ($0.location, $0) }
            )
            for checkpoint in additions {
                byLocation[checkpoint.location] = checkpoint
            }
            checkpoints = byLocation.values.sorted { $0.location < $1.location }
        }
    }

    private static let checkpointStride = 16 * 1_024
    private static let forwardChunkSize = 64 * 1_024

    static func supports(_ language: EditorLanguage) -> Bool {
        CodeLexicalScanner.supports(language)
    }

    static func match(
        in text: String,
        selection: NSRange,
        language: EditorLanguage,
        revision: UInt,
        context: Context,
        isCancelled: () -> Bool = { false }
    ) -> Match? {
        guard supports(language), selection.location != NSNotFound else { return nil }
        let string = text as NSString
        for candidate in candidateLocations(
            selection: selection,
            length: string.length
        ) {
            if let result = match(
                in: text,
                string: string,
                candidate: candidate,
                language: language,
                revision: revision,
                context: context,
                isCancelled: isCancelled
            ) {
                return result
            }
            if isCancelled() { return nil }
        }
        return nil
    }

    private static func candidateLocations(
        selection: NSRange,
        length: Int
    ) -> [Int] {
        if selection.length == 1,
           selection.location >= 0,
           selection.location < length {
            return [selection.location]
        }
        guard selection.length == 0 else { return [] }
        var result: [Int] = []
        if selection.location >= 0, selection.location < length {
            result.append(selection.location)
        }
        if selection.location > 0, selection.location - 1 < length {
            result.append(selection.location - 1)
        }
        return result
    }

    private static func match(
        in text: String,
        string: NSString,
        candidate: Int,
        language: EditorLanguage,
        revision: UInt,
        context: Context,
        isCancelled: () -> Bool
    ) -> Match? {
        let candidateValue = string.character(at: candidate)
        guard isOpening(candidateValue) || isClosing(candidateValue) else { return nil }

        let preparation = context.prepare(
            language: language,
            revision: revision,
            location: candidate
        )
        let checkpoint = preparation.checkpoint
        let prefixRange = NSRange(
            location: checkpoint.location,
            length: candidate - checkpoint.location + 1
        )
        let prefixProtected = CodeLexicalScanner.tokens(
            in: text,
            language: language,
            range: prefixRange,
            context: context.lexicalContext,
            revision: revision,
            isCancelled: isCancelled
        ).map(\.range).sorted { $0.location < $1.location }
        guard !contains(candidate, in: prefixProtected), !isCancelled() else { return nil }

        var stack = checkpoint.stack
        var additions: [Checkpoint] = []
        var lastCheckpoint = checkpoint.location
        var protectedIndex = 0
        var closingMatch: Match?

        scan(
            string: string,
            range: prefixRange,
            protectedRanges: prefixProtected,
            protectedIndex: &protectedIndex,
            stack: &stack,
            additions: &additions,
            lastCheckpoint: &lastCheckpoint,
            candidate: candidate,
            closingMatch: &closingMatch,
            isCancelled: isCancelled
        )
        guard !isCancelled() else { return nil }
        context.commit(
            additions,
            language: language,
            revision: revision,
            generation: preparation.generation
        )

        if isClosing(candidateValue) {
            return closingMatch
        }
        guard stack.last?.location == candidate else { return nil }

        let forwardStart = candidate + 1
        guard forwardStart < string.length else { return nil }
        additions.removeAll(keepingCapacity: true)
        lastCheckpoint = forwardStart
        var location = forwardStart
        while location < string.length {
            let chunkEnd = min(string.length, location + forwardChunkSize)
            let chunkRange = NSRange(
                location: location,
                length: chunkEnd - location
            )
            let protectedRanges = CodeLexicalScanner.tokens(
                in: text,
                language: language,
                range: chunkRange,
                context: context.lexicalContext,
                revision: revision,
                isCancelled: isCancelled
            ).map(\.range).sorted { $0.location < $1.location }
            guard !isCancelled() else { return nil }
            protectedIndex = 0

            while location < chunkEnd {
                if location.isMultiple(of: 4_096), isCancelled() { return nil }
                if skipProtected(
                    at: &location,
                    ranges: protectedRanges,
                    index: &protectedIndex
                ) {
                    continue
                }
                if location - lastCheckpoint >= checkpointStride {
                    additions.append(Checkpoint(location: location, stack: stack))
                    lastCheckpoint = location
                }
                let value = string.character(at: location)
                if isOpening(value) {
                    stack.append(Opening(location: location, value: value))
                } else if isClosing(value) {
                    guard let opening = stack.last, closes(value, opening.value) else {
                        return nil
                    }
                    stack.removeLast()
                    if opening.location == candidate {
                        context.commit(
                            additions,
                            language: language,
                            revision: revision,
                            generation: preparation.generation
                        )
                        return Match(
                            openingRange: NSRange(location: candidate, length: 1),
                            closingRange: NSRange(location: location, length: 1)
                        )
                    }
                }
                location += 1
            }
        }
        context.commit(
            additions,
            language: language,
            revision: revision,
            generation: preparation.generation
        )
        return nil
    }

    private static func scan(
        string: NSString,
        range: NSRange,
        protectedRanges: [NSRange],
        protectedIndex: inout Int,
        stack: inout [Opening],
        additions: inout [Checkpoint],
        lastCheckpoint: inout Int,
        candidate: Int,
        closingMatch: inout Match?,
        isCancelled: () -> Bool
    ) {
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            if location.isMultiple(of: 4_096), isCancelled() { return }
            if skipProtected(
                at: &location,
                ranges: protectedRanges,
                index: &protectedIndex
            ) {
                continue
            }
            if location - lastCheckpoint >= checkpointStride {
                additions.append(Checkpoint(location: location, stack: stack))
                lastCheckpoint = location
            }
            let value = string.character(at: location)
            if isOpening(value) {
                stack.append(Opening(location: location, value: value))
            } else if isClosing(value) {
                if let opening = stack.last, closes(value, opening.value) {
                    stack.removeLast()
                    if location == candidate {
                        closingMatch = Match(
                            openingRange: NSRange(location: opening.location, length: 1),
                            closingRange: NSRange(location: location, length: 1)
                        )
                    }
                } else if location == candidate {
                    closingMatch = nil
                } else {
                    stack.removeAll(keepingCapacity: true)
                }
            }
            location += 1
        }
    }

    private static func skipProtected(
        at location: inout Int,
        ranges: [NSRange],
        index: inout Int
    ) -> Bool {
        while index < ranges.count, NSMaxRange(ranges[index]) <= location {
            index += 1
        }
        guard index < ranges.count,
              NSLocationInRange(location, ranges[index]) else { return false }
        location = NSMaxRange(ranges[index])
        index += 1
        return true
    }

    private static func contains(_ location: Int, in ranges: [NSRange]) -> Bool {
        ranges.contains { NSLocationInRange(location, $0) }
    }

    private static func isOpening(_ value: unichar) -> Bool {
        value == 0x28 || value == 0x5B || value == 0x7B
    }

    private static func isClosing(_ value: unichar) -> Bool {
        value == 0x29 || value == 0x5D || value == 0x7D
    }

    private static func closes(_ closing: unichar, _ opening: unichar) -> Bool {
        (opening == 0x28 && closing == 0x29)
            || (opening == 0x5B && closing == 0x5D)
            || (opening == 0x7B && closing == 0x7D)
    }
}
