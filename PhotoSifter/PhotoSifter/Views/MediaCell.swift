import SwiftUI
import AppKit

/// A single media tile in the browser grid. Holds its thumbnail in a local
/// @State so an arriving thumbnail only re-renders THIS cell, not the grid.
struct MediaCell: View {
    let pair: MediaPair
    let isSelected: Bool
    let isMarked: Bool
    let jobStatus: BsideJobStatus?
    let size: CGFloat
    let viewMode: AppModel.ViewMode
    let fillMode: AppModel.FillMode
    let showFilename: Bool
    let showRawLabel: Bool

    @State private var image: NSImage? = nil
    @State private var loadFailed: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                thumbnailView
                    .frame(width: size, height: size)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(isSelected ? Color.theme : Color.clear, lineWidth: 3)
                    )

                statusBadges
            }
            if showFilename {
                Text(pair.displayName)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: size)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: taskKey) { await loadImage() }
    }

    /// Re-load when the source url, size, or view mode changes.
    private var taskKey: String {
        let prefer = viewMode == .merged ? pair.jpgItem?.url.path : ""
        return "\(pair.primary.url.path)|\(prefer)|\(Int(size))"
    }

    private func loadImage() async {
        // Fast path: already in cache (no async hop).
        let prefer = viewMode == .merged ? pair.jpgItem?.url : nil
        if let cached = ThumbnailCache.shared.cached(for: pair.primary, preferURL: prefer, size: size) {
            image = cached
            return
        }
        // Show placeholder while loading.
        image = nil
        let img = await ThumbnailCache.shared.load(for: pair.primary, preferURL: prefer, size: size)
        if Task.isCancelled { return }
        image = img
        loadFailed = (img == nil)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let image {
            imageView(image)
                .if(pair.isVideo) { view in
                    view.overlay(
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: min(34, size * 0.22)))
                            .foregroundStyle(.white.opacity(0.9), .black.opacity(0.45))
                    )
                }
                .overlay(alignment: .topLeading) { rawFormatBadge }
        } else if loadFailed {
            // Only show a failure indicator, never a spinner.
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                )
        } else {
            // Loading: silent placeholder, no spinner.
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor))
        }
    }

    /// Transparent RAW-format label (NEF/ARW/CR2…) shown when filenames hidden.
    @ViewBuilder
    private var rawFormatBadge: some View {
        if !showFilename, showRawLabel, pair.isVideo == false, let raw = pair.rawFile {
            Text(raw.url.pathExtension.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.35)))
                .padding(4)
        }
    }

    @ViewBuilder
    private func imageView(_ img: NSImage) -> some View {
        let aspect: ContentMode = (fillMode == .fill) ? .fill : .fit
        Image(nsImage: img)
            .resizable()
            .aspectRatio(contentMode: aspect)
            .frame(width: size, height: size)
            .clipped()
    }

    @ViewBuilder
    private var statusBadges: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if isMarked {
                badge(systemName: "trash.fill", color: Color.theme, label: "丢弃")
            }
            switch jobStatus {
            case .running:
                badge(systemName: "arrow.triangle.2.circlepath", color: .blue, label: nil)
            case .completed:
                if isMarked {
                    badge(systemName: "checkmark.circle.fill", color: .green, label: nil)
                }
            case .failed:
                badge(systemName: "exclamationmark.triangle.fill", color: .orange, label: nil)
            case .queued:
                badge(systemName: "hourglass", color: .gray, label: nil)
            case .none:
                EmptyView()
            case .some:
                EmptyView()
            }
        }
        .padding(4)
    }

    private func badge(systemName: String, color: Color, label: String?) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
            if let label {
                Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.92)))
        .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 0.5))
    }
}

private extension View {
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition { transform(self) } else { self }
    }
}
