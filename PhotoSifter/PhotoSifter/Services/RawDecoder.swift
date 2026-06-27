import Foundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers

/// Decodes RAW files via ImageIO. For preview/compression we prefer the
/// embedded JPEG preview (fast) when available, falling back to full decode.
enum RawDecoder {

    /// Returns a CGImage from a RAW source, preferring the embedded preview.
    static func decode(url: URL, maxDimension: Int? = nil) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // 1. Try the embedded JPEG preview (much faster than full RAW demosaic).
        if let preview = embeddedPreviewCGImage(src: src) {
            return preview
        }

        // 2. Full decode via ImageIO options.
        var options: [CFString: Any] = [:]
        if let maxDimension {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxDimension
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            options[kCGImageSourceShouldCacheImmediately] = true
            options[kCGImageSourceCreateThumbnailWithTransform] = true
        }
        return CGImageSourceCreateImageAtIndex(src, 0, options as CFDictionary)
    }

    private static func embeddedPreviewCGImage(src: CGImageSource) -> CGImage? {
        let count = CGImageSourceGetCount(src)
        // RAW files often embed smaller preview images at later indices.
        // Walk from the largest embedded index toward 0 (excluding index 0,
        // which is typically the full RAW).
        for i in stride(from: count - 1, through: 1, by: -1) {
            guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] else { continue }
            let width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
            let height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
            if width > 0 && height > 0 {
                if let img = CGImageSourceCreateImageAtIndex(src, i, nil) {
                    return img
                }
            }
        }
        return nil
    }
}
