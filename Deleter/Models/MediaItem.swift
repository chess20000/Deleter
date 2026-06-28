import Foundation
import UniformTypeIdentifiers
import ImageIO

/// A single media file (photo or video) on disk.
struct MediaItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let kind: Kind
    let isRaw: Bool
    /// Stable key for pairing: stem of filename (no extension).
    let stemKey: String
    /// Best-effort capture date (EXIF DateTimeOriginal), else file creation,
    /// else modification. Used for "by date" sorting.
    let dateTaken: Date

    enum Kind: Hashable {
        case image
        case video
    }

    init(url: URL, kind: Kind, isRaw: Bool) {
        self.id = UUID()
        self.url = url
        self.kind = kind
        self.isRaw = isRaw
        self.stemKey = url.deletingPathExtension().lastPathComponent
        self.dateTaken = MediaItem.captureDate(for: url)
    }

    var displayName: String { url.lastPathComponent }
    var filename: String { url.lastPathComponent }

    /// Resolve capture date: EXIF DateTimeOriginal → creationDate → modificationDate.
    private static func captureDate(for url: URL) -> Date {
        if let exif = readEXIFDate(url: url) { return exif }
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        let values = try? url.resourceValues(forKeys: keys)
        return values?.creationDate
            ?? values?.contentModificationDate
            ?? Date.distantPast
    }

    private static func readEXIFDate(url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let datetime = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
        guard let datetime else { return nil }
        return Self.exifFormatter.date(from: datetime)
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// Type classification for a file based on its extension.
enum MediaClassifier {
    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "dng", "pef",
        "srw", "3fr", "iiq", "mrw", "rwl", "x3f"
    ]
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "gif", "bmp"
    ]
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "m2ts", "mts", "wmv", "webm", "3gp"
    ]

    static func classify(url: URL) -> MediaItem.Kind? {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if imageExtensions.contains(ext) || rawExtensions.contains(ext) { return .image }
        // Fallback to UTType-based detection.
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        }
        return nil
    }

    static func isRaw(_ url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }
}
