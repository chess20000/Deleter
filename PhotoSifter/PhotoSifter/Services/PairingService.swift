import Foundation

/// Groups media items in a single directory into RAW+JPG pairs and standalone items.
enum PairingService {

    static func pair(items: [MediaItem]) -> [MediaPair] {
        // Bucket by stem key (filename without extension).
        var buckets: [String: [MediaItem]] = [:]
        for item in items {
            buckets[item.stemKey, default: []].append(item)
        }

        var pairs: [MediaPair] = []
        for (_, group) in buckets {
            let jpgs = group.filter { $0.kind == .image && !$0.isRaw }
            let raws = group.filter { $0.isRaw }
            let videos = group.filter { $0.kind == .video }

            if !videos.isEmpty {
                // Each video stands alone.
                for v in videos {
                    pairs.append(MediaPair(solo: v))
                }
                // If there happen to be jpg/raw with same stem, keep them standalone too.
                for j in jpgs { pairs.append(MediaPair(solo: j)) }
                for r in raws { pairs.append(MediaPair(solo: r)) }
                continue
            }

            if let raw = raws.first, let jpg = jpgs.first {
                // RAW + JPG pair (use first of each; rare to have multiple same-stem).
                pairs.append(MediaPair(jpgItem: jpg, rawItem: raw))
                for extra in jpgs.dropFirst() { pairs.append(MediaPair(solo: extra)) }
                for extra in raws.dropFirst() { pairs.append(MediaPair(solo: extra)) }
            } else {
                // No pairing possible; emit each standalone, preserving order.
                for j in jpgs { pairs.append(MediaPair(solo: j)) }
                for r in raws { pairs.append(MediaPair(solo: r)) }
            }
        }

        // Sort by primary filename for stable ordering.
        return pairs.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
}
