import Foundation

/// Lists the direct children (folders + media files) of a directory.
/// Non-recursive: sub-folder contents are only shown when the user navigates in.
/// Folder sizes, however, are computed recursively (cheap enumerator pass).
enum DirectoryScanner {

    struct ScanResult {
        let folders: [FolderEntry]
        let media: [MediaItem]
        /// Total bytes of media files directly in this directory (non-recursive).
        let currentDirBytes: Int64
    }

    static func scan(directory url: URL) throws -> ScanResult {
        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .nameKey, .fileSizeKey
        ]
        var folderURLs: [URL] = []
        var mediaURLs: [URL] = []
        var currentDirBytes: Int64 = 0

        let contents = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        )

        for itemURL in contents {
            let values = try? itemURL.resourceValues(forKeys: Set(resourceKeys))
            let isDir = values?.isDirectory ?? false
            if isDir {
                // Hide our own bside mirror folders so they don't clutter the
                // browser (e.g. AAA/AAA_bside/ should not appear as a tile).
                let name = itemURL.lastPathComponent
                if name.hasSuffix("_bside") { continue }
                folderURLs.append(itemURL)
            } else if (values?.isRegularFile ?? true) {
                if MediaClassifier.classify(url: itemURL) != nil {
                    mediaURLs.append(itemURL)
                    if let sz = values?.fileSize {
                        currentDirBytes += Int64(sz)
                    }
                }
            }
        }

        let folders = folderURLs
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { FolderEntry(url: $0, sizeBytes: recursiveSize(of: $0)) }

        let media = mediaURLs
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url -> MediaItem? in
                guard let kind = MediaClassifier.classify(url: url) else { return nil }
                return MediaItem(url: url, kind: kind, isRaw: MediaClassifier.isRaw(url))
            }

        return ScanResult(folders: folders, media: media, currentDirBytes: currentDirBytes)
    }

    /// Recursively sum file sizes under a directory (all files, not just media).
    private static func recursiveSize(of url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let sz = values?.fileSize {
                total += Int64(sz)
            }
        }
        return total
    }
}
