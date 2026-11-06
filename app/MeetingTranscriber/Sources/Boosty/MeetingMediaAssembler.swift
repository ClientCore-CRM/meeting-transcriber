@preconcurrency import AVFoundation
import Foundation

/// The existing app/mic mix stays the audio source of truth. Only its original
/// timeline is used: VAD-trimmed audio must never be substituted here.
enum MeetingMediaAssembler {
    static func assemble(video: CapturedMeetingVideo, audio: URL, audioHostStart: Double, output: URL) async throws -> URL {
        let videoAsset = AVURLAsset(url: video.path)
        let audioAsset = AVURLAsset(url: audio)
        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw MeetingVideoError.writer
        }
        let audioDuration = try await audioAsset.load(.duration)
        let videoDuration = try await videoAsset.load(.duration)
        let layout = MeetingCaptureClock.layout(
            videoStart: video.hostStart,
            audioStart: audioHostStart,
            videoDuration: videoDuration.seconds,
            audioDuration: audioDuration.seconds,
        )
        guard layout.duration > 0 else { throw MeetingVideoError.noFrames }
        let composition = AVMutableComposition()
        guard let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MeetingVideoError.writer
        }
        try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration), of: sourceAudio, at: .zero)
        let sourceStart = CMTime(seconds: layout.sourceStart, preferredTimescale: 600)
        let duration = CMTime(seconds: layout.duration, preferredTimescale: 600)
        let offset = CMTime(seconds: layout.offset, preferredTimescale: 600)
        try videoTrack.insertTimeRange(CMTimeRange(start: sourceStart, duration: duration), of: sourceVideo, at: offset)
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1920x1080) else {
            throw MeetingVideoError.writer
        }
        exporter.shouldOptimizeForNetworkUse = true
        if #available(macOS 15, *) {
            try await exporter.export(to: output, as: .mp4)
        } else {
            exporter.outputURL = output
            exporter.outputFileType = .mp4
            await exporter.export()
            guard exporter.status == .completed else { throw MeetingVideoError.writer }
        }
        return output
    }
}
