import Foundation

struct FileTreeNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let children: [FileTreeNode]?

    var id: URL { url }
    var name: String { url.lastPathComponent }
}
