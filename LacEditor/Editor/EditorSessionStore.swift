import AppKit
import Combine
import os

private let editorSessionPerformanceLog = OSLog(
    subsystem: "com.laceditor.LacEditor",
    category: "EditorPerformance"
)

final class EditorSessionStore: ObservableObject {
    struct Snapshot: Equatable {
        let documentIDs: Set<UUID>
        let inactiveDocumentIDs: Set<UUID>
        let inactiveMemoryCost: Int
    }

    private final class Entry {
        let coordinator: EditorTextView.Coordinator
        var scrollView: NSScrollView?
        var accessOrder: UInt

        init(
            coordinator: EditorTextView.Coordinator,
            accessOrder: UInt
        ) {
            self.coordinator = coordinator
            self.accessOrder = accessOrder
        }
    }

    private let limit: Int
    private let inactiveMemoryBudget: Int
    private let maximumCacheableSessionCost: Int
    private var entries: [UUID: Entry] = [:]
    private var accessOrder: UInt = 0
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(
        limit: Int,
        inactiveMemoryBudget: Int,
        maximumCacheableSessionCost: Int
    ) {
        self.limit = max(1, limit)
        self.inactiveMemoryBudget = max(0, inactiveMemoryBudget)
        self.maximumCacheableSessionCost = max(0, maximumCacheableSessionCost)
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            processMemoryPressure(source.data)
        }
        source.resume()
        memoryPressureSource = source
    }

    convenience init(limit: Int) {
        self.init(
            limit: limit,
            inactiveMemoryBudget: 64 * 1_024 * 1_024,
            maximumCacheableSessionCost: 24 * 1_024 * 1_024
        )
    }

    deinit {
        memoryPressureSource?.cancel()
    }

    func coordinator(for document: EditorDocument) -> EditorTextView.Coordinator {
        if let entry = entries[document.id] {
            touch(entry)
            return entry.coordinator
        }
        let coordinator = EditorTextView.Coordinator(document: document)
        accessOrder &+= 1
        entries[document.id] = Entry(
            coordinator: coordinator,
            accessOrder: accessOrder
        )
        trimIfNeeded()
        return coordinator
    }

    func cachedView(for documentID: UUID) -> NSScrollView? {
        guard let entry = entries[documentID],
              let scrollView = entry.scrollView else { return nil }
        touch(entry)
        scrollView.removeFromSuperview()
        return scrollView
    }

    func store(
        _ scrollView: NSScrollView,
        coordinator: EditorTextView.Coordinator,
        for documentID: UUID
    ) {
        let entry: Entry
        if let existing = entries[documentID] {
            entry = existing
        } else {
            accessOrder &+= 1
            entry = Entry(coordinator: coordinator, accessOrder: accessOrder)
            entries[documentID] = entry
        }
        entry.scrollView = scrollView
        touch(entry)
        trimIfNeeded()
    }

    func retainDocuments(_ documentIDs: Set<UUID>) {
        entries = entries.filter { documentIDs.contains($0.key) }
    }

    var snapshot: Snapshot {
        Snapshot(
            documentIDs: Set(entries.keys),
            inactiveDocumentIDs: Set(inactiveEntries.map(\.key)),
            inactiveMemoryCost: inactiveMemoryCost
        )
    }

    func processMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        let inactive = inactiveEntries.sorted {
            $0.value.accessOrder < $1.value.accessOrder
        }
        if event.contains(.critical) {
            inactive.forEach { evict($0.key) }
        } else if event.contains(.warning) {
            inactive.filter {
                $0.value.coordinator.estimatedMemoryCost > maximumCacheableSessionCost / 2
            }.forEach { evict($0.key) }
        }
    }

    private func touch(_ entry: Entry) {
        accessOrder &+= 1
        entry.accessOrder = accessOrder
    }

    private func trimIfNeeded() {
        while inactiveEntries.count > limit
                || inactiveMemoryCost > inactiveMemoryBudget
                || inactiveEntries.contains(where: {
                    $0.value.coordinator.estimatedMemoryCost > maximumCacheableSessionCost
                }) {
            let oversized = inactiveEntries
                .filter { $0.value.coordinator.estimatedMemoryCost > maximumCacheableSessionCost }
                .min { $0.value.accessOrder < $1.value.accessOrder }
            guard let victim = oversized ?? inactiveEntries.min(by: {
                $0.value.accessOrder < $1.value.accessOrder
            }) else { break }
            evict(victim.key)
        }
    }

    private var inactiveEntries: [(key: UUID, value: Entry)] {
        entries.filter { !$0.value.coordinator.isSessionActive }
    }

    private var inactiveMemoryCost: Int {
        inactiveEntries.reduce(0) { $0 + $1.value.coordinator.estimatedMemoryCost }
    }

    private func evict(_ documentID: UUID) {
        guard let entry = entries[documentID], !entry.coordinator.isSessionActive else { return }
        entry.coordinator.prepareForEviction()
        entry.coordinator.document.taskCoordinator.cancel(.search)
        entry.coordinator.document.taskCoordinator.cancel(.replace)
        entry.coordinator.document.taskCoordinator.cancel(.json)
        entry.coordinator.document.taskCoordinator.cancel(.preview)
        entry.coordinator.document.taskCoordinator.cancel(.delimiterMatch)
        os_signpost(
            .event,
            log: editorSessionPerformanceLog,
            name: "MemoryEviction"
        )
        entries.removeValue(forKey: documentID)
    }
}
