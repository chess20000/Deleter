import Foundation

/// A RAW + JPG pair sharing the same stem, OR a single standalone item.
/// In "merged" view a pair occupies one cell; in "split" view each item gets
/// its own cell (but marking D is linked).
struct MediaPair: Identifiable, Hashable {
    let id: UUID
    /// Non-nil when this pair is a RAW + JPG combo.
    let jpgItem: MediaItem?
    let rawItem: MediaItem?
    let soloItem: MediaItem?

    init(jpgItem: MediaItem?, rawItem: MediaItem?) {
        self.id = UUID()
        self.jpgItem = jpgItem
        self.rawItem = rawItem
        self.soloItem = nil
    }

    init(solo: MediaItem) {
        self.id = UUID()
        self.jpgItem = nil
        self.rawItem = nil
        self.soloItem = solo
    }

    var isPair: Bool { jpgItem != nil && rawItem != nil }
    var isVideo: Bool { primary.kind == .video }

    /// Preferred item for thumbnail / preview / compression (JPG first).
    var primary: MediaItem {
        if let soloItem { return soloItem }
        return jpgItem ?? rawItem!
    }

    /// Every original file behind this pair (for trashing).
    var allOriginals: [MediaItem] {
        if let soloItem { return [soloItem] }
        var items: [MediaItem] = []
        if let jpgItem { items.append(jpgItem) }
        if let rawItem { items.append(rawItem) }
        return items
    }

    var stemKey: String { primary.stemKey }
    /// Display name: for a RAW + non-RAW pair, show "IMG_0001.nef+jpg" /
    /// "IMG_0001.nef+hif" etc.; for a solo item, just its filename.
    var displayName: String {
        if isPair, let rawItem, let nonRawItem = jpgItem {
            let rawExt = rawItem.url.pathExtension
            let nonRawExt = nonRawItem.url.pathExtension
            return "\(stemKey).\(rawExt)+\(nonRawExt)"
        }
        return primary.displayName
    }
    var dateTaken: Date { primary.dateTaken }

    /// Any RAW file in this pair (the paired RAW, or a standalone RAW).
    var rawFile: MediaItem? {
        if let rawItem { return rawItem }
        if let soloItem, soloItem.isRaw { return soloItem }
        return nil
    }
    /// True if this pair contains any RAW file (paired or standalone).
    var containsRaw: Bool { rawFile != nil }
}
