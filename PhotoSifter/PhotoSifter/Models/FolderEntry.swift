import Foundation

/// A sub-folder entry shown as a tile in the browser (non-recursive browsing).
struct FolderEntry: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let name: String
    /// Total size in bytes of all files under this folder (recursive).
    let sizeBytes: Int64

    init(url: URL, sizeBytes: Int64 = 0) {
        self.id = UUID()
        self.url = url
        self.name = url.lastPathComponent
        self.sizeBytes = sizeBytes
    }
}
