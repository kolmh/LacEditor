import Foundation

struct SidebarFileGroup: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var isExpanded: Bool
    var paths: [String]

    init(id: UUID = UUID(), name: String, isExpanded: Bool = true, paths: [String] = []) {
        self.id = id
        self.name = name
        self.isExpanded = isExpanded
        self.paths = paths
    }

    var urls: [URL] { paths.map(URL.init(fileURLWithPath:)) }
}

enum SidebarLibrarySection: String, CaseIterable {
    case favorites
    case groups
    case recent
}

@MainActor
final class SidebarLibraryStore: ObservableObject {
    @Published private(set) var favoritePaths: [String] = []
    @Published private(set) var groups: [SidebarFileGroup] = []
    @Published private(set) var favoriteSectionExpanded = true
    @Published private(set) var groupsSectionExpanded = true
    @Published private(set) var recentSectionExpanded = true

    private struct Snapshot: Codable {
        var favoritePaths: [String]
        var groups: [SidebarFileGroup]
        var favoriteSectionExpanded: Bool?
        var groupsSectionExpanded: Bool?
        var recentSectionExpanded: Bool?
    }

    private let storageURL: URL

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        load()
    }

    var favoriteURLs: [URL] { favoritePaths.map(URL.init(fileURLWithPath:)) }

    func isFavorite(_ url: URL) -> Bool { favoritePaths.contains(canonicalPath(url)) }

    func isExpanded(_ section: SidebarLibrarySection) -> Bool {
        switch section {
        case .favorites: favoriteSectionExpanded
        case .groups: groupsSectionExpanded
        case .recent: recentSectionExpanded
        }
    }

    func setExpanded(_ expanded: Bool, for section: SidebarLibrarySection) {
        switch section {
        case .favorites: favoriteSectionExpanded = expanded
        case .groups: groupsSectionExpanded = expanded
        case .recent: recentSectionExpanded = expanded
        }
        persist()
    }

    func toggleFavorite(_ url: URL) {
        let path = canonicalPath(url)
        if let index = favoritePaths.firstIndex(of: path) {
            favoritePaths.remove(at: index)
        } else {
            favoritePaths.append(path)
        }
        persist()
    }

    @discardableResult
    func createGroup(named proposedName: String) -> UUID? {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let group = SidebarFileGroup(name: uniqueGroupName(from: name))
        groups.append(group)
        persist()
        return group.id
    }

    func renameGroup(_ id: UUID, to proposedName: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        groups[index].name = uniqueGroupName(from: name, excluding: id)
        persist()
    }

    func deleteGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        persist()
    }

    func setExpanded(_ expanded: Bool, for id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].isExpanded = expanded
        persist()
    }

    func add(_ url: URL, toGroup id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let path = canonicalPath(url)
        groups[index].paths.removeAll { $0 == path }
        groups[index].paths.append(path)
        persist()
    }

    func remove(_ url: URL, fromGroup id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].paths.removeAll { $0 == canonicalPath(url) }
        persist()
    }

    func moveFavorite(_ url: URL, before target: URL?) {
        movePath(canonicalPath(url), before: target.map(canonicalPath), in: &favoritePaths)
        persist()
    }

    func moveFile(_ url: URL, inGroup id: UUID, before target: URL?) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        movePath(canonicalPath(url), before: target.map(canonicalPath), in: &groups[index].paths)
        persist()
    }

    func moveGroup(_ id: UUID, before targetID: UUID?) {
        guard let source = groups.firstIndex(where: { $0.id == id }) else { return }
        let group = groups.remove(at: source)
        let destination = targetID.flatMap { target in
            groups.firstIndex(where: { $0.id == target })
        } ?? groups.endIndex
        groups.insert(group, at: destination)
        persist()
    }

    func replace(_ oldURL: URL, with newURL: URL) {
        let oldPath = canonicalPath(oldURL)
        let newPath = canonicalPath(newURL)
        favoritePaths = replacing(oldPath, with: newPath, in: favoritePaths)
        for index in groups.indices {
            groups[index].paths = replacing(oldPath, with: newPath, in: groups[index].paths)
        }
        persist()
    }

    func groupsContaining(_ url: URL) -> [UUID] {
        let path = canonicalPath(url)
        return groups.filter { $0.paths.contains(path) }.map(\.id)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        favoritePaths = deduplicated(snapshot.favoritePaths)
        favoriteSectionExpanded = snapshot.favoriteSectionExpanded ?? true
        groupsSectionExpanded = snapshot.groupsSectionExpanded ?? true
        recentSectionExpanded = snapshot.recentSectionExpanded ?? true
        groups = snapshot.groups.map { group in
            var group = group
            group.paths = deduplicated(group.paths)
            return group
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Snapshot(
                favoritePaths: favoritePaths,
                groups: groups,
                favoriteSectionExpanded: favoriteSectionExpanded,
                groupsSectionExpanded: groupsSectionExpanded,
                recentSectionExpanded: recentSectionExpanded
            ))
            try data.write(to: storageURL, options: .atomic)
        } catch {
            assertionFailure("Unable to persist sidebar library: \(error)")
        }
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func uniqueGroupName(from base: String, excluding id: UUID? = nil) -> String {
        let existing = Set(groups.filter { $0.id != id }.map { $0.name.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    private func movePath(_ path: String, before target: String?, in paths: inout [String]) {
        paths.removeAll { $0 == path }
        let destination = target.flatMap { paths.firstIndex(of: $0) } ?? paths.endIndex
        paths.insert(path, at: destination)
    }

    private func replacing(_ oldPath: String, with newPath: String, in paths: [String]) -> [String] {
        deduplicated(paths.map { $0 == oldPath ? newPath : $0 })
    }

    private func deduplicated(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    private static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LacEditor", isDirectory: true)
            .appendingPathComponent("SidebarLibrary.json")
    }
}
