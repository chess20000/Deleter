import Foundation

/// Resolves the bside (compressed copy) path for a source file.
///
/// Rule: the bside copy lives **inside the source file's own directory**, in a
/// sub-folder named `<dirname>_bside`. The file stem gets `_bside` and the
/// extension is replaced: images → .jpg, videos → .mp4.
///
///   AAA/img001.jpg            → AAA/AAA_bside/img001_bside.jpg
///   AAA/sub/B.cr2             → AAA/sub/sub_bside/B_bside.jpg
///
/// This "attach to the original directory" layout (rather than mirroring the
/// whole tree next to the root) means bside placement never depends on the
/// root's parent being writable — so it works on external-drive mount points
/// (e.g. `/Volumes/MyDrive/...`) without any special-casing.
enum BsidePathResolver {

    /// Given a source file URL, return its bside destination URL. The bside
    /// copy is placed in `<sourceDir>/<sourceDirName>_bside/<stem>_bside.<ext>`.
    static func destination(for source: URL) -> URL {
        let source = source.standardizedFileURL
        let dir = source.deletingLastPathComponent()
        let dirName = dir.lastPathComponent
        let bsideDir = dir.appendingPathComponent("\(dirName)_bside")

        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.lowercased()
        let newExt = MediaClassifier.videoExtensions.contains(ext) ? "mp4" : "jpg"
        let newName = "\(stem)_bside.\(newExt)"

        return bsideDir.appendingPathComponent(newName)
    }

    /// Creates the parent directory chain for a destination URL (lazy creation).
    static func ensureParentDir(for destination: URL) throws {
        let dir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
    }
}
