import SwiftUI

/// A folder tile in the browser grid.
struct FolderCell: View {
    let folder: FolderEntry
    let size: CGFloat
    let isSelected: Bool
    let showFilename: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(
                        colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.06)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: size, height: size)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                    )
                if showFilename {
                    Image(systemName: "folder.fill")
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(Color.accentColor.opacity(0.85))
                } else {
                    // Filename hidden: overlay the folder name inside the tile.
                    VStack(spacing: size * 0.06) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: size * 0.34))
                            .foregroundStyle(Color.accentColor.opacity(0.85))
                        Text(folder.name)
                            .font(.system(size: max(9, size * 0.12), weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 6)
                    }
                }
            }
            if showFilename {
                Text(folder.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: size)
                    .foregroundStyle(.primary)
            }
        }
    }
}
