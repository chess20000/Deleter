import SwiftUI
import AppKit
import AVKit
import AVFoundation

/// Wraps AVPlayerView for video playback in the quick-look overlay.
struct VideoPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .minimal
        view.player = AVPlayer(url: url)
        view.player?.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // Replace player when url changes.
        if (nsView.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            nsView.player?.pause()
            nsView.player = AVPlayer(url: url)
            nsView.player?.play()
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}
