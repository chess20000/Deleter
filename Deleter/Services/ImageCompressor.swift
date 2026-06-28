import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Produces a ~1080p JPEG copy at ~200KB by iteratively lowering quality.
enum ImageCompressor {

    /// Max dimension for the long edge (1080p ≈ 1920px long edge; we use 1920).
    static let maxLongEdge: CGFloat = 1920
    /// Soft target file size in bytes.
    static let targetBytes: Int = 200 * 1024
    /// Minimum acceptable JPEG quality floor.
    static let minQuality: CGFloat = 0.4

    enum CompressError: Error {
        case decodeFailed
        case writeFailed
    }

    /// Compress the source image to `destination`. Uses `preferSourceURL`
    /// (typically the JPG of a RAW+JPG pair) when provided.
    ///
    /// Cancellation: this is a cooperative cancellable — it periodically calls
    /// `Task.checkCancellation()` so an unmark mid-flight can stop the work
    /// promptly instead of running the full encode pipeline to completion.
    static func compress(
        source: URL,
        to destination: URL,
        preferSourceURL: URL? = nil
    ) throws {
        let resolved = preferSourceURL ?? source
        try Task.checkCancellation()
        let cgImage = try decodeCGImage(url: resolved)
        try Task.checkCancellation()
        try ensureParent(for: destination)
        try Task.checkCancellation()
        let data = try encodeTargetSize(cgImage: cgImage)
        try Task.checkCancellation()
        try data.write(to: destination, options: .atomic)
    }

    // MARK: - Decode

    private static func decodeCGImage(url: URL) throws -> CGImage {
        // RAW files: use RawDecoder (embedded preview first).
        if MediaClassifier.isRaw(url) {
            if let img = RawDecoder.decode(url: url, maxDimension: Int(maxLongEdge) * 2) {
                return img
            }
        }
        try Task.checkCancellation()
        // Regular images (JPG/PNG/HEIC/...): ImageIO full source.
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw CompressError.decodeFailed
        }
        return img
    }

    // MARK: - Encode

    /// Iteratively lower JPEG quality until ≤ targetBytes (or floor reached).
    private static func encodeTargetSize(cgImage: CGImage) throws -> Data {
        let scaled = scaleToMaxLongEdge(cgImage, maxLongEdge: maxLongEdge)

        let qualities: [CGFloat] = [0.85, 0.75, 0.65, 0.55, 0.45, minQuality]
        var bestData: Data? = nil
        for q in qualities {
            // Each encode is a full JPEG pass; check between passes so an
            // unmark can stop us promptly rather than finishing all levels.
            try Task.checkCancellation()
            guard let data = encodeJPEG(cgImage: scaled, quality: q) else { continue }
            bestData = data
            if data.count <= targetBytes {
                return data
            }
        }
        guard let bestData else { throw CompressError.writeFailed }
        return bestData
    }

    private static func encodeJPEG(cgImage: CGImage, quality: CGFloat) -> Data? {
        let mutable = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutable, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutable as Data
    }

    private static func scaleToMaxLongEdge(_ image: CGImage, maxLongEdge: CGFloat) -> CGImage {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let longEdge = max(w, h)
        guard longEdge > maxLongEdge else { return image }
        let scale = maxLongEdge / longEdge
        let newW = Int((w * scale).rounded())
        let newH = Int((h * scale).rounded())

        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return context.makeImage() ?? image
    }

    private static func ensureParent(for url: URL) throws {
        try BsidePathResolver.ensureParentDir(for: url)
    }
}
