import AVFoundation

@main
struct AssemblyCheck {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let first = directory.appendingPathComponent("first.mp4")
        let second = directory.appendingPathComponent("second.mp4")
        let joined = directory.appendingPathComponent("joined.mp4")
        try await RecordingAssembler.assemble(segments: [first, second], destination: joined)
        let asset = AVURLAsset(url: joined)
        let duration = try await asset.load(.duration).seconds
        guard abs(duration - 2) < 0.1 else { fatalError("Pause join duration incorrect: \(duration)") }
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard video.count == 1, !audio.isEmpty else { fatalError("Missing video or audio") }
        let mixedSingle = directory.appendingPathComponent("mixed-single.mp4")
        try await RecordingAssembler.assemble(segments: [first], destination: mixedSingle)
        let mixedAudio = try await AVURLAsset(url: mixedSingle).loadTracks(withMediaType: .audio)
        guard mixedAudio.count == 1 else { fatalError("Multiple sources were not mixed") }
        let silent = directory.appendingPathComponent("silent.mp4")
        let copy = directory.appendingPathComponent("copy.mp4")
        try await RecordingAssembler.assemble(segments: [silent], destination: copy)
        guard try Data(contentsOf: copy) == Data(contentsOf: silent) else { fatalError("Single segment changed") }
        let silentJoined = directory.appendingPathComponent("silent-joined.mp4")
        try await RecordingAssembler.assemble(segments: [silent, silent], destination: silentJoined)
        let silentAsset = AVURLAsset(url: silentJoined)
        guard try await silentAsset.loadTracks(withMediaType: .audio).isEmpty else { fatalError("Silent capture gained audio") }
        let silentDuration = try await silentAsset.load(.duration).seconds
        guard abs(silentDuration - 2) < 0.1 else { fatalError("Silent join duration incorrect") }
        print("PASS: pause join duration, video/audio tracks, single-segment integrity, silent pause join")
    }
}
