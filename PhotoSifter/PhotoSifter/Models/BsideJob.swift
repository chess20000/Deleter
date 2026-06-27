import Foundation

/// Lifecycle of a bside compression job.
enum BsideJobStatus: Hashable {
    case queued
    case running
    case completed
    case failed(String)   // error message
}

/// A background job that produces a compressed bside copy for one MediaPair.
struct BsideJob: Identifiable, Hashable {
    let id: UUID
    let pairId: UUID
    let sourceURL: URL
    let destinationURL: URL
    let isVideo: Bool
    var status: BsideJobStatus

    init(pairId: UUID, source: URL, destination: URL, isVideo: Bool) {
        self.id = UUID()
        self.pairId = pairId
        self.sourceURL = source
        self.destinationURL = destination
        self.isVideo = isVideo
        self.status = .queued
    }

    var isFinished: Bool {
        switch status {
        case .completed, .failed: return true
        default: return false
        }
    }

    var isInProgress: Bool {
        switch status {
        case .queued, .running: return true
        default: return false
        }
    }
}
