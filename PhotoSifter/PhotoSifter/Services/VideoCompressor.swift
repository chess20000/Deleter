import Foundation
import AVFoundation
import CoreVideo
import CoreImage

/// Transcodes videos to ~720p H.264 + AAC mp4. Optimized for speed & low bitrate.
enum VideoCompressor {

    static let maxLongEdge: CGFloat = 1280   // 720p long edge
    static let videoBitrate: Int = 2_000_000 // ~2 Mbps
    static let audioBitrate: Int = 96_000    // 96 kbps

    enum CompressError: Error {
        case noReadableTracks
        case readerCreationFailed
        case writerCreationFailed
        case writerInputNotReady
        case processingFailed(String)
    }

    static func compress(source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])

        // Build reader.
        let reader = try AVAssetReader(asset: asset)
        var videoReaderTrack: AVAssetReaderTrackOutput?
        var audioReaderTrack: AVAssetReaderTrackOutput?

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        if let vTrack = videoTracks.first {
            let output = AVAssetReaderTrackOutput(
                track: vTrack,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_32BGRA
                ]
            )
            output.alwaysCopiesSampleData = false
            reader.add(output)
            videoReaderTrack = output
        }

        if let aTrack = audioTracks.first {
            let output = AVAssetReaderTrackOutput(
                track: aTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM
                ]
            )
            output.alwaysCopiesSampleData = false
            reader.add(output)
            audioReaderTrack = output
        }

        guard videoReaderTrack != nil else { throw CompressError.noReadableTracks }

        // Build writer.
        try? FileManager.default.removeItem(at: destination)
        try BsidePathResolver.ensureParentDir(for: destination)

        guard let writer = try? AVAssetWriter(outputURL: destination, fileType: .mp4) else {
            throw CompressError.writerCreationFailed
        }

        // Video input: derive scaled dimensions preserving aspect ratio.
        var writerVideoInput: AVAssetWriterInput?
        if let vTrack = videoTracks.first {
            let transform = try await vTrack.load(.preferredTransform)
            let naturalSize = try await vTrack.load(.naturalSize)
            let dims = naturalSize.applying(transform)
            let w = abs(dims.width), h = abs(dims.height)
            let scaled = scaledDimensions(width: w, height: h, maxLongEdge: maxLongEdge)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: scaled.width,
                AVVideoHeightKey: scaled.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: videoBitrate,
                    AVVideoMaxKeyFrameIntervalKey: 60,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ] as [String: Any]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            // Keep source transform (adjusted if we scale differently).
            input.transform = transform
            writer.add(input)
            writerVideoInput = input
        }

        var writerAudioInput: AVAssetWriterInput?
        if audioTracks.first != nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: audioBitrate
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            writerAudioInput = input
        }

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let videoGroup = DispatchGroup()
        let errorBox = ErrorBox()

        // Video pipeline.
        if let vIn = writerVideoInput, let vOut = videoReaderTrack {
            videoGroup.enter()
            let queue = DispatchQueue(label: "bside.video")
            vIn.requestMediaDataWhenReady(on: queue) { [weak reader, weak writer] in
                guard let reader, let writer else { videoGroup.leave(); return }
                while vIn.isReadyForMoreMediaData {
                    if reader.status == .reading,
                       let sample = vOut.copyNextSampleBuffer() {
                        if !vIn.append(sample) {
                            errorBox.set("video append: \(writer.error?.localizedDescription ?? "?")")
                        }
                    } else {
                        vIn.markAsFinished()
                        videoGroup.leave()
                        return
                    }
                }
            }
        }

        // Audio pipeline.
        if let aIn = writerAudioInput, let aOut = audioReaderTrack {
            videoGroup.enter()
            let queue = DispatchQueue(label: "bside.audio")
            aIn.requestMediaDataWhenReady(on: queue) { [weak reader, weak writer] in
                guard let reader, let writer else { videoGroup.leave(); return }
                while aIn.isReadyForMoreMediaData {
                    if reader.status == .reading,
                       let sample = aOut.copyNextSampleBuffer() {
                        if !aIn.append(sample) {
                            errorBox.set("audio append: \(writer.error?.localizedDescription ?? "?")")
                        }
                    } else {
                        aIn.markAsFinished()
                        videoGroup.leave()
                        return
                    }
                }
            }
        }

        videoGroup.wait()

        if reader.status == .failed {
            throw CompressError.processingFailed(
                "reader: \(reader.error?.localizedDescription ?? "?")"
            )
        }

        writer.finishWriting {
            // completion handled by sync wait below
        }

        // Wait for writer to finish (poll, since finishWriting is async).
        let deadline = Date().addingTimeInterval(120)
        while writer.status == .writing && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if let err = errorBox.value {
            throw CompressError.processingFailed(err)
        }
        if writer.status == .failed {
            throw CompressError.processingFailed(
                "writer: \(writer.error?.localizedDescription ?? "?")"
            )
        }
        if writer.status != .completed {
            throw CompressError.processingFailed("writer did not complete (status \(writer.status.rawValue))")
        }
    }

    private static func scaledDimensions(width: CGFloat, height: CGFloat, maxLongEdge: CGFloat) -> (width: Int, height: Int) {
        let w = max(width, 1), h = max(height, 1)
        let longEdge = max(w, h)
        if longEdge <= maxLongEdge {
            return (Int(w.rounded()), Int(h.rounded()))
        }
        let scale = maxLongEdge / longEdge
        let nw = (w * scale).rounded()
        let nh = (h * scale).rounded()
        // Ensure even dimensions for H.264.
        return (evenInt(nw), evenInt(nh))
    }

    private static func evenInt(_ value: CGFloat) -> Int {
        var n = Int(value.rounded())
        if n % 2 != 0 { n += 1 }
        return max(2, n)
    }
}

private final class ErrorBox {
    private let lock = NSLock()
    private var _value: String?
    var value: String? {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func set(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        if _value == nil { _value = s }
    }
}
