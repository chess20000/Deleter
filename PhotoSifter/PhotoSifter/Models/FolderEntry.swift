import Foundation

/// A sub-folder entry shown as a tile in the browser (non-recursive browsing).
struct FolderEntry: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let name: String

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.name = url.lastPathComponent
    }
}
