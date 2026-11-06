import Foundation
import OSLog

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

extension WatchLoop {
    func enqueueRecording(
        title: String,
        appName: String,
        recording: RecordingResult,
        trigger: RecordingSidecar.Trigger,
        participants: [String] = [],
    ) {
        let capturedId = boostyCaptureId
        boostyCaptureId = nil
        if let capturedId { BoostyUploadQueue.current?.stopCapture(capturedId) }
        if recordOnly() {
            if let capturedId { BoostyUploadQueue.current?.markRecordOnly(capturedId) }
            do {
                try writeRecordOnlySidecar(
                    title: title, appName: appName, recording: recording, trigger: trigger, participants: participants,
                )
            } catch {
                reportRecordOnlyFailure(error)
            }
            return
        }

        var job = PipelineJob(
            meetingTitle: title,
            appName: appName,
            mixPath: recording.mixPath,
            appPath: recording.appPath,
            micPath: recording.micPath,
            micDelay: recording.micDelay,
            participants: participants,
            meetingStartTime: recording.recordingStartDate,
        )
        job.boostyCaptureId = capturedId
        pipelineQueue?.enqueue(job)
        logger.info("Enqueued pipeline job for: \(title, privacy: .private)")
    }
}
