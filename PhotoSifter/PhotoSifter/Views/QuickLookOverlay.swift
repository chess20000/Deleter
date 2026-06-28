import SwiftUI
import AppKit
import ImageIO

/// Full-screen quick-look style overlay. Space toggles; arrows navigate.
struct QuickLookOverlay: View {
    @ObservedObject var model: AppModel
    @State private var zoomScale: CGFloat = 1.0
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        if let idx = model.previewIndex, model.pairs.indices.contains(idx) {
            let pair = model.pairs[idx]
            ZStack {
                Color.black.opacity(0.96).ignoresSafeArea()
                content(for: pair)
                    .scaleEffect(zoomScale)
                    .offset(dragOffset)
                topLabel(pair)
                bottomCounter(idx)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func content(for pair: MediaPair) -> some View {
        if pair.isVideo {
            VideoPlayerView(url: pair.primary.url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            largeImage(for: pair)
        }
    }

    @ViewBuilder
    private func largeImage(for pair: MediaPair) -> some View {
        LargeImageView(url: pair.primary.url, preferURL: pair.jpgItem?.url)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func topLabel(_ pair: MediaPair) -> some View {
        VStack {
            HStack {
                Text(pair.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                if model.markedPairIds.contains(pair.id) {
                    Label("已标记丢弃", systemImage: "trash.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.theme)
                }
                Text("空格关闭 · ←→ 切换 · D 标记")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding()
            Spacer()
        }
    }

    private func bottomCounter(_ idx: Int) -> some View {
        VStack {
            Spacer()
            Text("\(idx + 1) / \(model.pairs.count)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.bottom, 16)
        }
    }
}

/// Loads a full-resolution image off the main thread.
struct LargeImageView: View {
    let url: URL
    let preferURL: URL?
    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(40)
            } else {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(.white)
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        let resolved = preferURL ?? url
        let isRaw = MediaClassifier.isRaw(resolved)
        let captured = resolved
        let img: NSImage? = await Task.detached(priority: .userInitiated) {
            if isRaw {
                if let cg = RawDecoder.decode(url: captured) {
                    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
            guard let src = CGImageSourceCreateWithURL(captured as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        await MainActor.run { self.image = img }
    }
}
