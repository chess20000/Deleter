import SwiftUI

/// The Finder-style grid of folders + media. Square cells with equal gutters
/// (= thumbnailSize / 20) both horizontally and vertically. Lazy rendering:
/// only on-screen cells materialize, so thumbnails load on demand.
struct BrowserGrid: View {
    @ObservedObject var model: AppModel

    /// Equal horizontal & vertical gap = 1/20 of the cell size.
    private var gutter: CGFloat { max(1, model.thumbnailSize / 20) }
    private let outerPadding: CGFloat = 8

    private func columnCount(forWidth width: CGFloat) -> Int {
        let usable = width - outerPadding * 2
        let cell = model.thumbnailSize + gutter
        return max(1, Int(usable / cell))
    }

    /// Fixed columns sized to the thumbnail size, with the exact gutter, so the
    /// horizontal gap never grows like .adaptive does. This guarantees equal
    /// horizontal & vertical spacing.
    private func columns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.fixed(model.thumbnailSize), spacing: gutter), count: count)
    }

    var body: some View {
        GeometryReader { geo in
            let colCount = columnCount(forWidth: geo.size.width)
            ScrollViewReader { proxy in
                ScrollView {
                    if let err = model.loadError {
                        Text(err).foregroundStyle(.red).padding()
                    }
                    LazyVGrid(columns: columns(colCount), spacing: gutter) {
                        ForEach(model.folders) { folder in
                            FolderCell(
                                folder: folder,
                                size: model.thumbnailSize,
                                isSelected: model.selectedFolderId == folder.id,
                                showFilename: model.showFilenames
                            )
                            .frame(width: model.thumbnailSize)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selection = .folder(folder.id)
                                model.lastSelectionByKeyboard = false
                            }
                            .accessibilityLabel("文件夹 \(folder.name)")
                            .id(folder.id)
                        }

                        ForEach(model.pairs) { pair in
                            MediaCell(
                                pair: pair,
                                isSelected: model.selectedPairId == pair.id,
                                isMarked: model.markedPairIds.contains(pair.id),
                                jobStatus: model.jobStatus[pair.id],
                                size: model.thumbnailSize,
                                viewMode: model.viewMode,
                                fillMode: model.fillMode,
                                showFilename: model.showFilenames,
                                showRawLabel: model.showRawLabel
                            )
                            .frame(width: model.thumbnailSize)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selection = .media(pair.id)
                                model.lastSelectionByKeyboard = false
                            }
                            .accessibilityLabel(pair.displayName)
                            .id(pair.id)
                        }
                    }
                    .padding(outerPadding)
                }
                .onChange(of: model.selection) { _, newSel in
                    guard let newSel else { return }
                    // Map selection back to the view id (both folders & pairs
                    // tag their view with the underlying UUID).
                    let viewId: UUID
                    switch newSel {
                    case .folder(let id): viewId = id
                    case .media(let id): viewId = id
                    }
                    let shouldScroll = model.lastSelectionByKeyboard
                        ? model.autoScrollOnNav
                        : model.autoScrollOnClick
                    guard shouldScroll else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(viewId, anchor: .center)
                    }
                }
            }
            .onAppear { model.gridColumns = colCount }
            .onChange(of: geo.size.width) { _, _ in model.gridColumns = colCount }
            .onChange(of: model.thumbnailSize) { _, _ in model.gridColumns = colCount }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
