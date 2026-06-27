import Foundation
import SwiftUI
import Combine

/// Central observable app state.
@MainActor
final class AppModel: ObservableObject {

    // Directory state.
    @Published var rootURL: URL?
    @Published var currentURL: URL?
    @Published var breadcrumb: [URL] = []        // root ... current
    @Published var folders: [FolderEntry] = []
    @Published var pairs: [MediaPair] = []
    /// Unified selection over the visible grid (folders first, then media).
    @Published var selection: GridSelection?
    @Published var viewMode: ViewMode = .merged  // merged vs split
    @Published var fillMode: FillMode = .fill    // square grid: fill (crop) vs fit (whole image)
    @Published var sortMode: SortMode = .name    // sort by name or capture date
    @Published var showFilenames: Bool = true    // show filename under each cell
    @Published var showRawLabel: Bool = true     // show RAW format badge when filenames hidden
    @Published var autoScrollOnNav: Bool = true  // scroll selected cell into view on arrow keys
    @Published var autoScrollOnClick: Bool = true // scroll selected cell into view on click
    /// Tracks how the current selection changed, so the grid can decide
    /// whether to autoscroll (nav vs click have independent toggles).
    @Published var lastSelectionByKeyboard: Bool = false
    @Published var thumbnailSize: CGFloat = 160
    @Published var gridColumns: Int = 1          // measured by BrowserGrid
    @Published var loadError: String?

    // Selection / preview.
    @Published var previewIndex: Int? = nil      // non-nil ⇒ quick-look overlay open

    // Marking / jobs.
    @Published var markedPairIds: Set<UUID> = [] // user marked for discard
    @Published var jobStatus: [UUID: BsideJobStatus] = [:]  // by pairId
    @Published var schedulerProgress: BsideScheduler.Progress = .init()
    @Published var failedPairIds: Set<UUID> = []
    @Published var isTrashing: Bool = false
    @Published var lastTrashResult: String?

    // Cache of generated bside destinations for session restore.
    @Published var restoredCompleted: Set<UUID> = []

    let scheduler = BsideScheduler()
    private var progressTask: Task<Void, Never>?

    enum ViewMode { case merged, split }
    enum FillMode { case fill, fit }
    enum SortMode { case name, date }

    /// A single selectable item in the grid (folder or media pair).
    enum GridSelection: Hashable {
        case folder(UUID)
        case media(UUID)
    }

    /// Flat ordered list of grid items: folders first, then media pairs.
    var gridItems: [GridSelection] {
        folders.map { .folder($0.id) } + pairs.map { .media($0.id) }
    }

    /// Derived: the selected media pair id, if a media item is selected.
    var selectedPairId: UUID? {
        if case .media(let id) = selection { return id }
        return nil
    }
    /// Derived: the selected folder id, if a folder is selected.
    var selectedFolderId: UUID? {
        if case .folder(let id) = selection { return id }
        return nil
    }

    init() {
        startProgressObservation()
    }

    // MARK: - Directory loading

    func openRoot(_ url: URL) {
        rootURL = url
        currentURL = url
        breadcrumb = [url]
        navigate(to: url)
    }

    func navigate(to url: URL) {
        currentURL = url
        // Rebuild breadcrumb from root.
        if let root = rootURL {
            var path: [URL] = []
            var cur: URL? = url
            while let c = cur, c.path != "/" {
                path.insert(c, at: 0)
                if c.path == root.path { break }
                cur = c.deletingLastPathComponent()
            }
            // Ensure root is the first element.
            if path.first != root { path.insert(root, at: 0) }
            breadcrumb = path
        }
        loadError = nil
        do {
            let result = try DirectoryScanner.scan(directory: url)
            folders = result.folders
            let grouped = PairingService.pair(items: result.media)
            pairs = grouped
            resortPairs()
            // Select the first grid item (folder if any, else first media).
            selection = gridItems.first
            restoreMarkings(for: grouped)
        } catch {
            folders = []
            pairs = []
            loadError = "无法读取目录：\(error.localizedDescription)"
        }
    }

    func goUp() {
        guard breadcrumb.count > 1 else { return }
        let parent = breadcrumb[breadcrumb.count - 2]
        navigate(to: parent)
    }

    func openFolder(_ folder: FolderEntry) {
        navigate(to: folder.url)
    }

    /// Change sort mode and re-sort the current list.
    func setSortMode(_ mode: SortMode) {
        sortMode = mode
        resortPairs()
    }

    private func resortPairs() {
        switch sortMode {
        case .name:
            pairs.sort {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        case .date:
            pairs.sort { $0.dateTaken < $1.dateTaken }
        }
    }

    // MARK: - Session restore

    /// Scan bside tree to recover "marked + completed" state for pairs whose
    /// bside copy already exists.
    private func restoreMarkings(for grouped: [MediaPair]) {
        guard let root = rootURL else { return }
        for pair in grouped {
            let dest = BsidePathResolver.destination(for: pair.primary.url, root: root)
            if FileManager.default.fileExists(atPath: dest.path) {
                markedPairIds.insert(pair.id)
                jobStatus[pair.id] = .completed
                restoredCompleted.insert(pair.id)
            }
        }
    }

    // MARK: - Marking / D key

    func toggleMark(for pairId: UUID) {
        if markedPairIds.contains(pairId) {
            unmark(pairId: pairId)
        } else {
            mark(pairId: pairId)
        }
    }

    /// D-key logic (taught by the user, do not change the flow):
    ///   1. Look at the current selection.
    ///   2. If it's a folder → do nothing.
    ///   3. If it's a photo/video:
    ///        a. Already marked? → unmark + delete the bside file. Stay here.
    ///        b. Not marked?     → mark + enqueue bside task + press ➡️ (next item).
    /// Only the "mark" branch advances; "unmark" stays put.
    func markCurrentAndAdvance(inPreview: Bool) {
        // Resolve the currently selected pair id (only media counts).
        let pairId: UUID?
        if inPreview {
            if let i = previewIndex, pairs.indices.contains(i) {
                pairId = pairs[i].id
            } else {
                pairId = nil
            }
        } else {
            pairId = selectedPairId   // nil when a folder (or nothing) is selected
        }
        // Step 1+2: folder / nothing selected → ignore.
        guard let pairId else { return }

        // Step 3a: already marked → unmark + delete bside, stay put.
        if markedPairIds.contains(pairId) {
            unmark(pairId: pairId)
            return
        }
        // Step 3b: not marked → mark + enqueue, then ➡️.
        mark(pairId: pairId)
        if inPreview {
            previewMove(by: 1)
        } else {
            moveSelection(by: 1)
        }
    }

    private func mark(pairId: UUID) {
        guard let pair = pair(by: pairId), let root = rootURL else { return }
        markedPairIds.insert(pairId)

        // If a completed copy already exists (restored), nothing to schedule.
        if case .completed = jobStatus[pairId] { return }

        let source = pair.primary.url
        let dest = BsidePathResolver.destination(for: source, root: root)
        let isVideo = pair.isVideo
        jobStatus[pairId] = .queued

        let capturedPairId = pairId
        let capturedSource = source
        let capturedDest = dest
        Task {
            await scheduler.enqueue(
                id: capturedPairId,
                displayName: capturedDest.lastPathComponent
            ) { [weak self] in
                await self?.runCompression(
                    pairId: capturedPairId,
                    source: capturedSource,
                    dest: capturedDest,
                    isVideo: isVideo,
                    preferSource: pair.jpgItem?.url
                )
            }
        }
    }

    private func unmark(pairId: UUID) {
        markedPairIds.remove(pairId)
        let status = jobStatus[pairId]
        // Per user spec: unmarking always deletes the bside file if it exists,
        // regardless of job state, keeping the bside mirror clean.
        if let root = rootURL, let pair = pair(by: pairId) {
            let dest = BsidePathResolver.destination(for: pair.primary.url, root: root)
            try? FileManager.default.removeItem(at: dest)
        }
        switch status {
        case .queued:
            Task { await scheduler.cancelQueued(id: pairId) }
            jobStatus[pairId] = nil
        case .completed:
            jobStatus[pairId] = nil
            restoredCompleted.remove(pairId)
        case .running:
            // Can't safely cancel mid-run; the bside file (if partially written)
            // was removed above. Mark cleared so it won't be trashed.
            jobStatus[pairId] = nil
        case .failed, .none:
            jobStatus[pairId] = nil
            failedPairIds.remove(pairId)
        }
    }

    private func pair(by id: UUID) -> MediaPair? {
        pairs.first { $0.id == id }
    }

    // MARK: - Compression execution

    private func runCompression(
        pairId: UUID,
        source: URL,
        dest: URL,
        isVideo: Bool,
        preferSource: URL?
    ) async {
        await MainActor.run {
            self.jobStatus[pairId] = .running
        }
        do {
            if isVideo {
                try await Task.detached(priority: .utility) {
                    try await VideoCompressor.compress(source: source, to: dest)
                }.value
            } else {
                try await Task.detached(priority: .utility) {
                    try ImageCompressor.compress(
                        source: source, to: dest, preferSourceURL: preferSource
                    )
                }.value
            }
            await MainActor.run {
                self.jobStatus[pairId] = .completed
                self.failedPairIds.remove(pairId)
            }
        } catch {
            await MainActor.run {
                self.jobStatus[pairId] = .failed(error.localizedDescription)
                self.failedPairIds.insert(pairId)
            }
        }
    }

    // MARK: - Discard originals

    var discardableCount: Int {
        markedPairIds.filter { id in
            if case .completed = jobStatus[id] { return true }
            return false
        }.count
    }

    func discardOriginals() {
        guard !isTrashing else { return }
        let toTrash = pairs.filter { pair in
            markedPairIds.contains(pair.id) &&
            (jobStatus[pair.id].map { if case .completed = $0 { return true }; return false } ?? false)
        }
        guard !toTrash.isEmpty else { return }
        isTrashing = true
        let urls = toTrash.flatMap { $0.allOriginals.map { $0.url } }
        let pairIds = Set(toTrash.map { $0.id })
        Task {
            let (trashed, failed) = TrashService.trash(urls: urls)
            await MainActor.run {
                for id in pairIds {
                    self.markedPairIds.remove(id)
                    self.jobStatus[id] = nil
                    self.failedPairIds.remove(id)
                    self.restoredCompleted.remove(id)
                }
                // Remove trashed pairs from the current list.
                self.pairs.removeAll { pairIds.contains($0.id) }
                // If the selection was trashed, move to the first remaining item.
                if case .media(let sel) = self.selection, pairIds.contains(sel) {
                    self.selection = self.gridItems.first
                }
                self.isTrashing = false
                self.lastTrashResult = "已丢弃 \(trashed.count) 个文件" +
                    (failed.isEmpty ? "" : "，\(failed.count) 个失败")
            }
        }
    }

    // MARK: - Progress observation

    private func startProgressObservation() {
        progressTask = Task { [weak self] in
            guard let self else { return }
            for await p in await self.scheduler.observeProgress() {
                await MainActor.run {
                    self.schedulerProgress = p
                }
            }
        }
    }

    // MARK: - Navigation helpers

    /// Index of the current selection in gridItems, or 0 if none.
    private var selectionIndex: Int {
        guard let sel = selection else { return 0 }
        return gridItems.firstIndex(of: sel) ?? 0
    }

    func moveSelection(by delta: Int) {
        let items = gridItems
        guard !items.isEmpty else { return }
        let idx = selectionIndex
        let newIdx = (idx + delta + items.count) % items.count
        selection = items[newIdx]
        lastSelectionByKeyboard = true
    }

    /// Arrow navigation over the unified grid (folders + media).
    /// Left/right = linear ±1 (wraps across the folder/media boundary).
    /// Up/down = ± one full row (measured column count).
    func moveSelection(direction: GridDirection) {
        let items = gridItems
        guard !items.isEmpty else { return }
        let cols = max(1, gridColumns)
        let idx = selectionIndex
        let count = items.count
        var newIdx = idx
        switch direction {
        case .left:  newIdx = max(0, idx - 1)
        case .right: newIdx = min(count - 1, idx + 1)
        case .up:    newIdx = max(0, idx - cols)
        case .down:  newIdx = min(count - 1, idx + cols)
        }
        guard newIdx != idx else { return }
        selection = items[newIdx]
        lastSelectionByKeyboard = true
    }

    enum GridDirection { case up, down, left, right }

    /// Open the selected folder (Enter on a folder tile).
    func openSelectedFolder() {
        guard case .folder(let id) = selection,
              let folder = folders.first(where: { $0.id == id }) else { return }
        openFolder(folder)
    }

    var selectedIndex: Int {
        selectionIndex
    }

    func openPreview() {
        guard selectedPairId != nil else { return }
        // previewIndex is an index into pairs only.
        if let pid = selectedPairId, let i = pairs.firstIndex(where: { $0.id == pid }) {
            previewIndex = i
        }
    }

    func closePreview() {
        previewIndex = nil
    }

    func previewMove(by delta: Int) {
        guard var i = previewIndex, !pairs.isEmpty else { return }
        let count = pairs.count
        i = (i + delta + count) % count
        previewIndex = i
        selection = .media(pairs[i].id)
    }
}
