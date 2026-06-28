import Foundation
import SwiftUI
import Combine
#if canImport(Darwin)
import Darwin
#endif

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
    /// True while a directory scan is in flight; the grid shows a spinner overlay.
    @Published var isLoading: Bool = false

    // Disk / directory space (shown in the top bar as 40G/50G/128G).
    /// Bytes of media files directly in the current directory.
    @Published var currentDirBytes: Int64 = 0
    /// Bytes of media files in the root directory (captured when root is opened).
    @Published var rootDirBytes: Int64 = 0
    /// Free bytes on the volume that holds the root directory.
    @Published var freeSpaceBytes: Int64 = 0

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
    /// Monotonic token so only the latest navigate() can commit results.
    private var navToken: Int = 0

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
        // Capture the root's media size + volume free space in the background.
        // rootDirBytes is refreshed when the root scan completes (navigate sets
        // currentDirBytes, and for the root they're the same); free space is
        // queried from the volume directly.
        Task.detached(priority: .utility) { [weak self] in
            let free = Self.freeSpace(of: url)
            await MainActor.run {
                guard let self else { return }
                self.freeSpaceBytes = free
            }
        }
    }

    /// Free bytes on the volume containing the given URL.
    nonisolated private static func freeSpace(of url: URL) -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let cap = values.volumeAvailableCapacityForImportantUsage {
                return cap
            }
        } catch {}
        // Fallback: statvfs.
        var stat = statvfs()
        if statvfs(url.path, &stat) == 0 {
            return Int64(stat.f_bavail) * Int64(stat.f_frsize)
        }
        return 0
    }

    /// Format a byte count as a compact human-readable size, e.g. "40G", "1.2T", "512M".
    nonisolated static func formatBytes(_ bytes: Int64) -> String {
        let units: [(String, Int64)] = [("T", 1 << 40), ("G", 1 << 30), ("M", 1 << 20), ("K", 1 << 10)]
        for (suffix, threshold) in units {
            if bytes >= threshold {
                let value = Double(bytes) / Double(threshold)
                // Show one decimal when < 10, else round to integer.
                if value < 10 {
                    return String(format: "%.1f%@", value, suffix)
                }
                return "\(Int(value.rounded()))\(suffix)"
            }
        }
        return "\(bytes)B"
    }

    func navigate(to url: URL) {
        navigate(to: url, selectURL: nil)
    }

    func navigate(to url: URL, selectURL: URL?) {
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
        isLoading = true

        // Only the most recent navigate() may commit results; stale tasks
        // from rapid folder changes are discarded by token comparison.
        navToken &+= 1
        let token = navToken

        Task.detached(priority: .userInitiated) { [weak self] in
            let result: DirectoryScanner.ScanResult?
            do {
                result = try await Task.detached { try DirectoryScanner.scan(directory: url) }.value
            } catch {
                await MainActor.run {
                    guard let self, self.navToken == token else { return }
                    self.folders = []
                    self.pairs = []
                    self.loadError = "无法读取目录：\(error.localizedDescription)"
                    self.isLoading = false
                }
                return
            }
            guard let result else { return }
            let grouped = PairingService.pair(items: result.media)

            await MainActor.run {
                guard let self, self.navToken == token else { return }
                self.folders = result.folders
                self.pairs = grouped
                self.resortPairs()
                self.currentDirBytes = result.currentDirBytes
                // When at the root, the current dir's size IS the root size.
                if url.path == self.rootURL?.path {
                    self.rootDirBytes = result.currentDirBytes
                }
                // When returning up a folder (goUp), keep the selection on the
                // sub-folder we just came out of, instead of jumping to the
                // first item.
                if let target = selectURL,
                   let folder = result.folders.first(where: { $0.url.path == target.path }) {
                    self.selection = .folder(folder.id)
                } else {
                    self.selection = self.gridItems.first
                }
                self.restoreMarkings(for: grouped)
                self.isLoading = false
            }
        }
    }

    func goUp() {
        guard breadcrumb.count > 1 else { return }
        // Close any open preview so it doesn't dangle over the new directory
        // (its previewIndex would be stale / out of bounds after navigation).
        closePreview()
        let parent = breadcrumb[breadcrumb.count - 2]
        // Remember the folder we're leaving so the selection lands on it after
        // navigating up — instead of jumping back to the first item.
        let leavingURL = currentURL
        navigate(to: parent, selectURL: leavingURL)
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
                $0.stemKey.localizedStandardCompare($1.stemKey) == .orderedAscending
            }
        case .date:
            pairs.sort { $0.dateTaken < $1.dateTaken }
        }
    }

    // MARK: - Session restore

    /// Scan for existing bside copies to recover "marked + completed" state.
    private func restoreMarkings(for grouped: [MediaPair]) {
        for pair in grouped {
            let dest = BsidePathResolver.destination(for: pair.primary.url)
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
        guard let pair = pair(by: pairId) else { return }
        markedPairIds.insert(pairId)

        // If a completed copy already exists (restored), nothing to schedule.
        if case .completed = jobStatus[pairId] { return }

        let source = pair.primary.url
        let dest = BsidePathResolver.destination(for: source)
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
        if let pair = pair(by: pairId) {
            let dest = BsidePathResolver.destination(for: pair.primary.url)
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
            // Cancel the in-flight compression immediately. The work will
            // observe cancellation, bail out, and clear its own status — so we
            // don't touch jobStatus here (the running task owns it until it
            // returns). The partial bside file was already removed above.
            Task { await scheduler.cancelRunning(id: pairId) }
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
            // Run the heavy work in this (cancellable) task context. We do NOT
            // use Task.detached here: a detached task cannot be cancelled from
            // the outside, and we need unmark → scheduler.cancelRunning to be
            // able to stop a compression in progress.
            if isVideo {
                try await VideoCompressor.compress(source: source, to: dest)
            } else {
                // ImageCompressor.compress is synchronous (throws but not async);
                // it still honors Task cancellation via checkCancellation().
                try ImageCompressor.compress(
                    source: source, to: dest, preferSourceURL: preferSource
                )
            }
            // Bail out silently if the user cancelled while we were finishing.
            if Task.isCancelled { return }
            await MainActor.run {
                // Guard against the re-mark race: if the pair was unmarked and
                // re-marked while we ran, a fresh job owns the status now.
                guard self.markedPairIds.contains(pairId) else { return }
                self.jobStatus[pairId] = .completed
                self.failedPairIds.remove(pairId)
            }
        } catch is CancellationError {
            // User unmarked mid-flight: clean up any partial output (unmark
            // already removed the bside file, but be defensive) and leave the
            // status cleared. Do NOT record as failed. Guard against the
            // re-mark race: if the pair was marked again before we got here,
            // a fresh job owns the status now — don't clobber it.
            try? FileManager.default.removeItem(at: dest)
            await MainActor.run {
                if !self.markedPairIds.contains(pairId) {
                    self.jobStatus[pairId] = nil
                }
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
