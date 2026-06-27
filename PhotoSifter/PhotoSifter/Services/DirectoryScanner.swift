import Foundation

/// Lists the direct children (folders + media files) of a directory.
/// Non-recursive: sub-folder contents are only shown when the user navigates in.
enum DirectoryScanner {

    struct ScanResult {
        let folders: [FolderEntry]
        let media: [MediaItem]
    }

    static func scan(directory url: URL) throws -> ScanResult {
        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .nameKey
        ]
        var folderURLs: [URL] = []
        var mediaURLs: [URL] = []

        let contents = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        )

        for itemURL in contents {
            let values = try? itemURL.resourceValues(forKeys: Set(resourceKeys))
            let isDir = values?.isDirectory ?? false
            if isDir {
                folderURLs.append(itemURL)
            } else if (values?.isRegularFile ?? true) {
                if MediaClassifier.classify(url: itemURL) != nil {
                    mediaURLs.append(itemURL)
                }
            }
        }

        let folders = folderURLs
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { FolderEntry(url: $0) }

        let media = mediaURLs
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url -> MediaItem? in
                guard let kind = MediaClassifier.classify(url: url) else { return nil }
                return MediaItem(url: url, kind: kind, isRaw: MediaClassifier.isRaw(url))
            }

        return ScanResult(folders: folders, media: media)
    }
}
