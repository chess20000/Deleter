import SwiftUI
import AppKit
import QuickLookThumbnailing
import ImageIO
import Combine

/// Thumbnail loader backed by the system QuickLook thumbnail service
/// (`QLThumbnailGenerator`) — the same engine Finder uses. Benefits:
///   - System-managed disk cache → repeat opens are instant
///   - Native RAW / HEIC / video frame support (no manual decode)
///   - Fast & low-CPU
///
/// IMPORTANT: this cache does NOT publish global change notifications, because
/// doing so forces the entire grid to re-render on every thumbnail arrival
/// (the cause of click/scroll lag). Instead each cell loads its own image
/// asynchronously into a local @State, so a thumbnail arriving only re-renders
/// that one cell.
@MainActor
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()

    private var cache: [String: NSImage] = [:]
    private var inFlight: [String: [CheckedContinuation<NSImage?, Never>]] = [:]
    private let generator = QLThumbnailGenerator.shared

    /// Synchronously returns a cached image if present, else nil. Never triggers.
    func cached(for item: MediaItem, preferURL: URL? = nil, size: CGFloat) -> NSImage? {
        cache[cacheKey(url: preferURL ?? item.url, size: size)]
    }

    /// Asynchronously load and return the image. Coalesces concurrent requests
    /// for the same key so we never decode the same file twice.
    func load(for item: MediaItem, preferURL: URL? = nil, size: CGFloat) async -> NSImage? {
        let source = preferURL ?? item.url
        let key = cacheKey(url: source, size: size)
        if let cached = cache[key] { return cached }
        return await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            if inFlight[key] != nil {
                inFlight[key, default: []].append(cont)
            } else {
                inFlight[key] = [cont]
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                let dimension = max(64, Int(size * scale))
                requestQL(url: source, key: key, dimension: dimension)
            }
        }
    }

    // MARK: - QuickLook request

    private func requestQL(url: URL, key: String, dimension: Int) {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: dimension, height: dimension),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )
        generator.generateBestRepresentation(for: request) { [weak self] rep, _ in
            Task { @MainActor in
                guard let self else { return }
                let img: NSImage?
                if let rep {
                    img = rep.nsImage ?? NSImage(cgImage: rep.cgImage, size: request.size)
                } else {
                    img = await Self.fallbackDecode(url: url, maxEdge: dimension)
                }
                if let img { self.cache[key] = img }
                let waiters = self.inFlight.removeValue(forKey: key) ?? []
                for w in waiters { w.resume(returning: img) }
            }
        }
    }

    // MARK: - Cache key
    // Path + size only. We deliberately do NOT stat the file's mtime here,
    // because doing so triggers synchronous disk I/O on every cell render —
    // the cause of click/arrow lag. Files don't change during a session.
    private func cacheKey(url: URL, size: CGFloat) -> String {
        "\(url.path)|\(Int(size))"
    }

    // MARK: - Fallback (ImageIO)

    private nonisolated static func fallbackDecode(url: URL, maxEdge: Int) async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let img = fallbackSync(url: url, maxEdge: maxEdge)
                continuation.resume(returning: img)
            }
        }
    }

    nonisolated private static func fallbackSync(url: URL, maxEdge: Int) -> NSImage? {
        if MediaClassifier.isRaw(url) {
            if let cg = RawDecoder.decode(url: url, maxDimension: maxEdge) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
