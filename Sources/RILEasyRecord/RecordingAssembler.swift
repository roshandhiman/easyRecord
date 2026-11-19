import AVFoundation

/// Joins finalized capture segments without adding the time spent paused.
/// Audio tracks are kept separate through composition and mixed into the MP4 export.
enum RecordingAssembler {
    static func assemble(segments: [URL], destination: URL) async throws {
        guard !segments.isEmpty else { throw AssemblyError.empty }
        if segments.count == 1, try await AVURLAsset(url: segments[0]).loadTracks(withMediaType: .audio).count <= 1 {
            try FileManager.default.copyItem(at: segments[0], to: destination)
            return
        }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw AssemblyError.empty }
        var audioTracks: [AVMutableCompositionTrack] = []
        var cursor = CMTime.zero
        for url in segments {
            let asset = AVURLAsset(url: url)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { throw AssemblyError.empty }
            let range = try await sourceVideo.load(.timeRange)
            try video.insertTimeRange(range, of: sourceVideo, at: cursor)
            if cursor == .zero { video.preferredTransform = try await sourceVideo.load(.preferredTransform) }
            let sourceAudio = try await asset.loadTracks(withMediaType: .audio)
            for (index, track) in sourceAudio.enumerated() {
                while audioTracks.count <= index {
                    guard let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw AssemblyError.empty }
                    audioTracks.append(audio)
                }
                let audioRange = CMTimeRangeGetIntersection(try await track.load(.timeRange), otherRange: range)
                if audioRange.duration > .zero {
                    let offset = CMTimeSubtract(audioRange.start, range.start)
                    try audioTracks[index].insertTimeRange(audioRange, of: track, at: CMTimeAdd(cursor, offset))
                }
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw AssemblyError.empty }
        if !audioTracks.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioTracks.map { track in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(1 / Float(audioTracks.count), at: .zero)
                return parameters
            }
            exporter.audioMix = mix
        }
        exporter.shouldOptimizeForNetworkUse = true
        try await exporter.export(to: destination, as: .mp4)
    }

    private enum AssemblyError: LocalizedError {
        case empty
        var errorDescription: String? { "The recording has no playable video." }
    }
}
