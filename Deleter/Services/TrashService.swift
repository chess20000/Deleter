import Foundation
import AppKit

/// Moves files/folders to the Trash (recoverable via Finder).
enum TrashService {

    @discardableResult
    static func trash(urls: [URL]) -> (trashed: [URL], failed: [(URL, Error)]) {
        var trashed: [URL] = []
        var failed: [(URL, Error)] = []
        for url in urls {
            do {
                var resultURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultURL)
                trashed.append(url)
            } catch {
                failed.append((url, error))
            }
        }
        return (trashed, failed)
    }
}
