import Foundation

/// Resolves the bside mirror path for any source file or folder.
///
/// Rule: every path component (including the selected root) gets a `_bside`
/// suffix, and the file stem gets `_bside` too. The file extension is replaced:
/// images → .jpg, videos → .mp4.
///
/// Example:  xxx/subA/subB/IMG_0001.cr2
///      →    xxx_bside/subA_bside/subB_bside/IMG_0001_bside.jpg
enum BsidePathResolver {

    /// The bside root that sits next to the selected root directory.
    static func bsideRoot(for root: URL) -> URL {
        let parent = root.deletingLastPathComponent()
        return parent.appendingPathComponent(root.lastPathComponent + "_bside")
    }

    /// Given the selected root and a source file URL (anywhere under root),
    /// return the bside destination URL.
    static func destination(for source: URL, root: URL) -> URL {
        // Relative path components from root down to the file's parent dir.
        let rootPath = root.standardizedFileURL.path
        let sourcePath = source.standardizedFileURL.path
        let relPath = String(sourcePath.dropFirst(rootPath.count))
        // relPath looks like "/subA/subB/IMG_0001.cr2"
        var comps = relPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // Last component is the filename; transform it.
        guard let filename = comps.popLast() else {
            return bsideRoot(for: root).appendingPathComponent("unnamed_bside.jpg")
        }
        let sourceURL = URL(fileURLWithPath: filename)
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension.lowercased()
        let newExt: String
        if MediaClassifier.videoExtensions.contains(ext) {
            newExt = "mp4"
        } else {
            newExt = "jpg"
        }
        let newName = "\(stem)_bside.\(newExt)"

        var dest = bsideRoot(for: root)
        for comp in comps {
            dest = dest.appendingPathComponent(comp + "_bside")
        }
        dest = dest.appendingPathComponent(newName)
        return dest
    }

    /// Creates the parent directory chain for a destination URL (lazy creation).
    static func ensureParentDir(for destination: URL) throws {
        let dir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
    }
}
