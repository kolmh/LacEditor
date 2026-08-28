import Foundation

/// A single post-edit description shared by document analysis consumers.
/// Ranges use UTF-16 offsets, matching NSTextStorage and NSLayoutManager.
struct DocumentEditDelta: Sendable, Equatable {
    let documentID: UUID
    let revision: UInt
    let editedRange: NSRange
    let replacementLength: Int
    let changeInLength: Int
    let changedLineRange: NSRange?
}

/// Coalesces edits while preserving the positions of edits that occur after
/// an insertion or deletion. Consumers can process the union after typing
/// settles instead of scheduling one scan per keystroke.
struct DirtyRangeAccumulator: Sendable, Equatable {
    private(set) var ranges: [NSRange] = []

    var isEmpty: Bool { ranges.isEmpty }

    var unionRange: NSRange? {
        guard let first = ranges.first else { return nil }
        return ranges.dropFirst().reduce(first) { $0.union($1) }
    }

    mutating func clear() {
        ranges.removeAll(keepingCapacity: true)
    }

    mutating func invalidate(_ range: NSRange) {
        guard range.location != NSNotFound else { return }
        ranges.append(range)
        mergeOverlappingRanges()
    }

    mutating func append(_ edit: DocumentEditDelta) {
        // Existing ranges are stored in the post-edit coordinate space. The
        // newly edited span therefore uses the replacement length, while
        // ranges after the old span are translated by the length delta.
        let replacementRange = NSRange(
            location: edit.editedRange.location,
            length: edit.replacementLength
        )
        let oldEnd = edit.editedRange.upperBound

        var updated: [NSRange] = []
        updated.reserveCapacity(ranges.count + 1)
        var inserted = false

        for range in ranges {
            if range.upperBound <= edit.editedRange.location {
                updated.append(range)
                continue
            }

            if range.location >= oldEnd {
                updated.append(NSRange(
                    location: max(0, range.location + edit.changeInLength),
                    length: range.length
                ))
                continue
            }

            if replacementRange.touches(range) || edit.editedRange.touches(range) {
                updated.append(range.union(replacementRange))
                inserted = true
            } else {
                updated.append(range)
            }
        }

        if !inserted {
            updated.append(replacementRange)
        }
        ranges = updated
        mergeOverlappingRanges()
    }

    private mutating func mergeOverlappingRanges() {
        ranges.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        merged.reserveCapacity(ranges.count)
        for range in ranges where range.location != NSNotFound {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if last.touches(range) {
                merged[merged.count - 1] = last.union(range)
            } else {
                merged.append(range)
            }
        }
        ranges = merged
    }
}

struct DocumentTextSnapshot: Sendable, Equatable {
    let documentID: UUID
    let revision: UInt
    let text: String

    var utf16Length: Int { (text as NSString).length }
    var byteCount: Int { text.utf8.count }
}

private extension NSRange {
    var upperBound: Int { location + length }

    func touches(_ other: NSRange) -> Bool {
        location <= other.upperBound && other.location <= upperBound
    }

    func union(_ other: NSRange) -> NSRange {
        let start = min(location, other.location)
        let end = max(upperBound, other.upperBound)
        return NSRange(location: start, length: end - start)
    }
}
