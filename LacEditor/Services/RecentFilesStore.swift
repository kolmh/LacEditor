import Foundation

@MainActor
final class RecentFilesStore: ObservableObject {
    @Published private(set) var urls: [URL] = []

    private let key = "recentFilePaths"
    private let maximumCount = 12

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        urls = paths.map(URL.init(fileURLWithPath:))
    }

    func record(_ url: URL) {
        urls.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        urls.insert(url, at: 0)
        urls = Array(urls.prefix(maximumCount))
        persist()
    }

    func clear() {
        urls = []
        persist()
    }

    func remove(_ url: URL) {
        urls.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        persist()
    }

    func replace(_ oldURL: URL, with newURL: URL) {
        let oldURL = oldURL.standardizedFileURL
        let newURL = newURL.standardizedFileURL
        urls = urls.map {
            $0.standardizedFileURL == oldURL ? newURL : $0
        }
        var seen: Set<URL> = []
        urls = urls.filter { seen.insert($0.standardizedFileURL).inserted }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(urls.map(\.path), forKey: key)
    }
}
