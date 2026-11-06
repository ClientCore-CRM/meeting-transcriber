import AppKit
import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

struct CapturedMeetingVideo: Codable, Sendable {
    let path: URL
    let hostStart: Double
    let duration: Double
    let warnings: [String]
}

enum MeetingVideoError: Error, LocalizedError {
    case permission, noWindow, noFrames, writer
    var errorDescription: String? {
        switch self {
        case .permission: "Allow Screen Recording in macOS Settings to capture the meeting window."
        case .noWindow: "No meeting window selected. Audio recording continues."
        case .noFrames: "The meeting window delivered no video frames."
        case .writer: "The meeting video could not be saved. Audio recording continues."
        }
    }
}

/// Mutable writer state is confined to frameQueue; lifecycle methods await the
/// stream stopping before finalizing the writer on that same queue.
final class MeetingWindowRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let frameQueue = DispatchQueue(label: "ru.clientcore.boosty.window-video")
    private var windowIdentity: MeetingWindowCandidate?
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var lastFrame: CMSampleBuffer?
    private var interruptionPTS: CMTime?
    private var warnings: [String] = []
    private let output: URL
    private let onFirstFrame: @Sendable (Double) -> Void

    init(output: URL, onFirstFrame: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.output = output
        self.onFirstFrame = onFirstFrame
    }

    @MainActor
    static func chooseWindow(pid: pid_t, title: String) async throws -> CGWindowID {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw MeetingVideoError.permission }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let candidates = content.windows
            .filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width >= 120 && $0.frame.height >= 80 }
        let values = candidates.map { MeetingWindowCandidate(id: $0.windowID, pid: pid, title: $0.title ?? "") }
        if let id = MeetingWindowSelection.automatic(values, pid: pid, title: title) { return id }
        guard !candidates.isEmpty else { throw MeetingVideoError.noWindow }
        let alert = NSAlert()
        alert.messageText = "Choose the meeting window"
        alert.informativeText = "Only this window will be recorded. Other windows and your desktop are excluded."
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
        picker.addItems(withTitles: candidates.enumerated().map { index, window in
            "\(index + 1). \(window.title?.isEmpty == false ? (window.title ?? "Meeting window") : "Untitled window")"
        })
        alert.accessoryView = picker
        alert.addButton(withTitle: "Record this window")
        alert.addButton(withTitle: "Audio only")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { throw MeetingVideoError.noWindow }
        return candidates[picker.indexOfSelectedItem].windowID
    }

    func start(windowID: CGWindowID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw MeetingVideoError.noWindow }
        guard let owner = window.owningApplication, let title = window.title, !title.isEmpty else { throw MeetingVideoError.noWindow }
        windowIdentity = .init(id: window.windowID, pid: owner.processID, title: title)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = min(1, min(1920 / window.frame.width, 1080 / window.frame.height))
        configuration.width = max(2, Int(window.frame.width * scale) / 2 * 2)
        configuration.height = max(2, Int(window.frame.height * scale) / 2 * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.queueDepth = 3
        configuration.capturesAudio = false
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000, AVVideoMaxKeyFrameIntervalKey: 30],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw MeetingVideoError.writer }
        writer.add(input)
        self.writer = writer
        self.input = input
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int else { return }
        if status == SCFrameStatus.suspended.rawValue || status == SCFrameStatus.blank.rawValue {
            let warning = "Meeting-window video was suspended or blank for part of the recording."
            if !warnings.contains(warning) { warnings.append(warning) }
        }
        guard status == SCFrameStatus.complete.rawValue, let writer, let input else { return }
        guard interruptionPTS == nil else { return }
        guard let identity = windowIdentity, MeetingWindowSelection.continues(expected: identity, current: currentWindow(identity.id)) else {
            interruptionPTS = sampleBuffer.presentationTimeStamp
            warnings.append("Meeting-window identity changed or could not be verified. Video capture ended before saving changed content.")
            return
        }
        let pts = sampleBuffer.presentationTimeStamp
        if firstPTS == nil {
            guard writer.startWriting() else { warnings.append("Video writer could not start."); return }
            writer.startSession(atSourceTime: pts)
            firstPTS = pts
            onFirstFrame(pts.seconds)
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer) {
            lastPTS = pts
            lastFrame = sampleBuffer
        } else if warnings.isEmpty {
            warnings.append("Some meeting-window frames could not be saved.")
        }
    }

    private func currentWindow(_ id: CGWindowID) -> MeetingWindowCandidate? {
        guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let info = windows.first,
              let title = info[kCGWindowName as String] as? String,
              let pid = info[kCGWindowOwnerPID as String] as? Int32 else { return nil }
        return .init(id: id, pid: pid, title: title)
    }

    func stream(_: SCStream, didStopWithError _: any Error) {
        let stoppedAt = CMClockGetTime(CMClockGetHostTimeClock())
        frameQueue.async { [self] in
            interruptionPTS = stoppedAt
            warnings.append("Meeting-window capture stopped before the audio recording ended.")
        }
    }

    func stop() async throws -> CapturedMeetingVideo {
        if let stream { try? await stream.stopCapture() }
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        return try await withCheckedThrowingContinuation { continuation in
            frameQueue.async { [self] in
                finishWriting(at: end, continuation: continuation)
            }
        }
    }

    private func finishWriting(at end: CMTime, continuation: CheckedContinuation<CapturedMeetingVideo, any Error>) {
        guard let writer, let input, let firstPTS, let lastPTS, writer.status == .writing else {
            continuation.resume(throwing: MeetingVideoError.noFrames)
            return
        }
        // ScreenCaptureKit may stop producing frames for a static window.
        // Repeating the last frame gives the recording its real end time.
        let stopTime = CMTimeMaximum(lastPTS, interruptionPTS ?? end)
        // H.264 requires strictly increasing PTS. An interruption can end exactly
        // at the last frame; duplicating that timestamp can fail finalization.
        if let lastFrame, CMTimeCompare(stopTime, lastPTS) > 0, input.isReadyForMoreMediaData {
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 15), presentationTimeStamp: stopTime, decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            if CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: lastFrame,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleBufferOut: &copy,
            ) == noErr, let copy {
                _ = input.append(copy)
            }
        }
        writer.endSession(atSourceTime: stopTime)
        input.markAsFinished()
        let captured = CapturedMeetingVideo(
            path: output,
            hostStart: firstPTS.seconds,
            duration: max(0, (stopTime - firstPTS).seconds),
            warnings: warnings,
        )
        writer.finishWriting { [self] in
            frameQueue.async { [self] in
                guard self.writer?.status == .completed else {
                    continuation.resume(throwing: MeetingVideoError.writer)
                    return
                }
                continuation.resume(returning: captured)
            }
        }
    }
}
