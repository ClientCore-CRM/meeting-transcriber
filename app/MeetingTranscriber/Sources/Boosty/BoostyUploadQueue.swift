import AVFoundation
import CoreMedia
import Foundation
import Observation

/// Durable, account-bound exports. Network operations yield the main actor;
/// encoding, media assembly and checksumming run on a detached task.
@MainActor
@Observable
final class BoostyUploadQueue {
    static var current: BoostyUploadQueue?
    static let shared: BoostyUploadQueue = {
        let queue = BoostyUploadQueue(root: AppPaths.dataDir.appendingPathComponent("boosty"))
        current = queue
        return queue
    }()

    private(set) var entries: [BoostyUploadEntry] = []
    private(set) var storageError: String?
    private let store: BoostyUploadStore
    private var worker: Task<Void, Never>?
    private var captureWatcher: Task<Void, Never>?
    private var pumping = false
    private var requestingStart: Set<UUID> = []
    private var preparing: Set<UUID> = []
    private var videoRecorders: [UUID: MeetingWindowRecorder] = [:]
    private var videoStarts: [UUID: Task<Void, Never>] = [:]
    private var videoStops: [UUID: Task<Void, Never>] = [:]

    init(root: URL) {
        store = BoostyUploadStore(root: root)
        do {
            entries = try store.load()
            for index in entries.indices where entries[index].captureStoppedAt == nil {
                entries[index].captureStoppedAt = entries[index].lastCaptureAt ?? entries[index].startedAt
                entries[index].warnings.append("The app restarted during this recording; upload recovery is in progress.")
            }
        } catch { storageError = "The upload queue could not be recovered. Its media files have been kept." }
    }

    func resume() {
        guard worker == nil, storageError == nil else { return }
        captureWatcher = Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    for entry in entries where entry.stopAcknowledged != true {
                        if entry.serverRecordingId == nil { await requestStart(entry.id) }
                        await observeCapture(entry.id)
                    }
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pump()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func persist() {
        do { try store.save(entries) } catch { storageError = "Could not save the upload queue. Keep this app open and check available disk space." }
    }

    func mutate(_ id: UUID, _ body: (inout BoostyUploadEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        body(&entries[index])
        persist()
    }

    func begin(pid: pid_t?, title: String, startedAt: Date, stagingStem: String?) -> UUID? {
        let connection = BoostyConnectionState.shared
        guard worker != nil, storageError == nil, connection.uploadEnabled, let credential = connection.credential else { return nil }
        let id = UUID()
        let hostStart: Double? = nil
        let entry = BoostyUploadEntry(
            id: id,
            origin: credential.origin,
            accountKey: credential.accountKey,
            title: title,
            startedAt: startedAt,
            audioHostStart: hostStart,
            stagingStem: stagingStem,
        )
        var initial = entry
        initial.lastCaptureAt = startedAt
        entries.append(initial)
        persist()
        guard storageError == nil else { return nil }
        Task {
            if let pid {
                let url = await Task.detached(priority: .userInitiated) { MeetingURLReader.read(pid: pid) }.value
                mutate(id) { $0.meetingURL = url }
            }
            await requestStart(id)
        }
        if let pid {
            videoStarts[id] = Task { [weak self] in
                guard let self else { return }
                do {
                    let directory = try store.directory(for: id)
                    let recorder = MeetingWindowRecorder(output: directory.appendingPathComponent("window.mp4")) { [weak self] firstTime in
                        Task { @MainActor in self?.mutate(id) { $0.rawVideoHostStart = firstTime } }
                    }
                    videoRecorders[id] = recorder
                    let window = try await MeetingWindowRecorder.chooseWindow(pid: pid, title: title)
                    try await recorder.start(windowID: window)
                } catch {
                    mutate(id) { $0.warnings.append(error.localizedDescription) }
                }
            }
        } else {
            mutate(id) { $0.warnings.append("Microphone-only recording has no meeting-window video.") }
        }
        return id
    }

    func stopCapture(_ id: UUID, audioHostStart: Double? = nil) {
        mutate(id) { $0.captureStoppedAt = Date(); $0.audioHostStart = audioHostStart }
        Task { await observeCapture(id) }
        videoStops[id] = Task { [weak self] in
            guard let self else { return }
            await videoStarts[id]?.value
            if let recorder = videoRecorders.removeValue(forKey: id) {
                do {
                    let video = try await recorder.stop()
                    mutate(id) { $0.video = video }
                } catch {
                    mutate(id) { $0.warnings.append(error.localizedDescription) }
                }
            }
            videoStarts.removeValue(forKey: id)
            mutate(id) { if $0.status == "Recording" { $0.status = "Processing on this Mac" } }
        }
    }

    func matchingCapture(mixPath: URL?) -> UUID? {
        guard let mixPath else { return nil }
        return entries.first { entry in
            guard let stem = entry.stagingStem else { return false }
            return mixPath.lastPathComponent == stem + "_mix.wav"
        }?.id
    }

    func selectMeeting(_ id: UUID, meetingId: String?) {
        mutate(id) { entry in
            entry.selectedMeetingId = meetingId
            entry.skipCalendarSelection = meetingId == nil
        }
        Task { await requestStart(id) }
    }

    func markRecordOnly(_ id: UUID) {
        mutate(id) { $0.status = "Record-only mode: no transcript or summary was generated" }
    }

    private func observeCapture(_ id: UUID) async {
        guard let entry = entries.first(where: { $0.id == id }), let serverId = entry.serverRecordingId,
              entry.stopAcknowledged != true else { return }
        do {
            let credential = try activeCredential(for: entry)
            if entry.captureStoppedAt == nil { mutate(id) { $0.lastCaptureAt = Date() } }
            struct CaptureState: Encodable { let stoppedAt: Date? }
            let client = try BoostyAPIClient(origin: entry.origin)
            let state: BoostyRecordingState = try await client.send(
                path: "/api/desktop/recordings/\(serverId)/capture-state",
                method: "POST",
                token: credential.deviceToken,
                body: BoostyAPIClient.encoder().encode(CaptureState(stoppedAt: entry.captureStoppedAt)),
            )
            mutate(id) { draft in
                draft.botStatus = state.botStatus
                if entry.captureStoppedAt != nil { draft.stopAcknowledged = true }
            }
        } catch {
            mutate(id) { $0.botStatus = "Cancellation not confirmed: \(error.localizedDescription)" }
        }
    }

    private func activeCredential(for entry: BoostyUploadEntry) throws -> BoostyCredential {
        guard BoostyConnectionState.shared.uploadEnabled,
              let credential = BoostyConnectionState.shared.credential,
              credential.accountKey == entry.accountKey, credential.origin == entry.origin,
              credential.expiresAt > Date() else { throw BoostyError.disconnected }
        return credential
    }

    func requestStart(_ id: UUID) async {
        guard !requestingStart.contains(id), let entry = entries.first(where: { $0.id == id }) else { return }
        requestingStart.insert(id)
        defer { requestingStart.remove(id) }
        do {
            let credential = try activeCredential(for: entry)
            let client = try BoostyAPIClient(origin: entry.origin)
            let body = BoostyStart(
                clientRecordingId: id,
                startedAt: entry.startedAt,
                meetingId: entry.selectedMeetingId,
                meetingUrl: entry.meetingURL,
            )
            let result: BoostyRecordingState = try await client.send(
                path: "/api/desktop/recordings/start",
                method: "POST",
                token: credential.deviceToken,
                body: BoostyAPIClient.encoder().encode(body),
            )
            guard UUID(uuidString: result.recordingId) != nil else { throw BoostyError.invalidResponse }
            mutate(id) { draft in
                draft.serverRecordingId = result.recordingId
                draft.botStatus = result.botStatus
                draft.candidates = result.candidates ?? []
            }
        } catch {
            mutate(id) { $0.botStatus = "Not confirmed: \(error.localizedDescription)" }
        }
    }

    func prepare(captureId: UUID, segments: [BoostyExportSegment], summary: String?, audio: URL) {
        guard entries.contains(where: { $0.id == captureId }) else { return }
        mutate(captureId) { $0.pendingExport = .init(segments: segments, summary: summary, audio: audio) }
        guard !preparing.contains(captureId), let entry = entries.first(where: { $0.id == captureId }) else { return }
        preparing.insert(captureId)
        Task { [weak self] in
            await self?.prepareExport(entry: entry, segments: segments, summary: summary, audio: audio)
        }
    }

    private func prepareExport(entry: BoostyUploadEntry, segments: [BoostyExportSegment], summary: String?, audio: URL) async {
        let captureId = entry.id
        defer { preparing.remove(captureId) }
        do {
            let fingerprint = try BoostyExportPolicy.fingerprint(segments: segments, summary: summary)
            if entry.snapshot?.fingerprint == fingerprint {
                mutate(captureId) { $0.pendingExport = nil }
                return
            }
            await videoStops[captureId]?.value
            var current = entries.first { $0.id == captureId } ?? entry
            let directory = try store.directory(for: captureId)
            // Fragmented MP4 survives a process interruption; never pretend its
            // unfinalized tail is a complete capture.
            if current.video == nil, let first = current.rawVideoHostStart {
                let raw = directory.appendingPathComponent("window.mp4")
                if let duration = try? await AVURLAsset(url: raw).load(.duration).seconds, duration > 0 {
                    current.video = .init(
                        path: raw,
                        hostStart: first,
                        duration: duration,
                        warnings: ["Meeting-window video was recovered after an interrupted recording."],
                    )
                }
            }
            let revision = (current.snapshot?.revision ?? 0) + 1
            let immutable = current
            let snapshot = try await Task.detached(priority: .utility) {
                try await BoostyExportBuilder.build(
                    entry: immutable,
                    segments: segments,
                    summary: summary,
                    audio: audio,
                    destination: (revision: revision, directory: directory),
                )
            }.value
            mutate(captureId) { draft in
                draft.snapshot = snapshot
                if let pending = draft.pendingExport,
                   (try? BoostyExportPolicy.fingerprint(segments: pending.segments, summary: pending.summary)) == snapshot.fingerprint {
                    draft.pendingExport = nil
                }
                draft.status = summary == nil ? "Ready; summary is missing" : "Ready to upload"
                draft.nextAttempt = .distantPast
            }
            await pump()
        } catch {
            mutate(captureId) { draft in
                draft.status = "Export needs attention: \(error.localizedDescription)"
                draft.nextAttempt = Date().addingTimeInterval(60)
            }
        }
    }

    func retry(_ id: UUID) {
        mutate(id) { $0.nextAttempt = .distantPast; $0.failures = 0 }
        Task { await pump() }
    }

    private func pump() async {
        guard !pumping, storageError == nil else { return }
        pumping = true
        defer { pumping = false }
        for entry in entries {
            guard entry.nextAttempt <= Date() else { continue }
            if let pending = entry.pendingExport, !preparing.contains(entry.id) {
                prepare(captureId: entry.id, segments: pending.segments, summary: pending.summary, audio: pending.audio)
            }
            if entry.serverRecordingId == nil {
                await requestStart(entry.id)
            }
            guard entry.snapshot != nil, entry.uploadedRevision != entry.snapshot?.revision else { continue }
            do { try await upload(entry.id) } catch {
                mutate(entry.id) { draft in
                    draft.failures = min(draft.failures + 1, 10)
                    draft.status = "Upload pending: \(error.localizedDescription)"
                    switch error {
                    case BoostyError.resultConflict, BoostyError.http(422): draft.nextAttempt = .distantFuture
                    default: draft.nextAttempt = Date().addingTimeInterval(min(300, pow(2, Double(draft.failures)) * 5))
                    }
                }
            }
        }
    }

    private func upload(_ id: UUID) async throws {
        guard let entry = entries.first(where: { $0.id == id }), let snapshot = entry.snapshot else { return }
        if !entry.candidates.isEmpty && entry.selectedMeetingId == nil && !entry.skipCalendarSelection {
            mutate(id) { $0.status = "Choose the calendar meeting to cancel its bot" }
            return
        }
        let credential = try activeCredential(for: entry)
        guard let serverId = entry.serverRecordingId else { throw BoostyError.invalidResponse }
        let client = try BoostyAPIClient(origin: entry.origin)
        let path = "/api/desktop/recordings/\(serverId)"
        var state: BoostyRecordingState = try await client.send(path: path, token: credential.deviceToken)
        mutate(id) { $0.botStatus = state.botStatus }
        if BoostyUploadPolicy.waitForValidation(serverRevision: state.sourceRevision, status: state.importStatus, desiredRevision: snapshot.revision) { return }
        if state.receipt.sourceRevision == snapshot.revision && ["uploaded", "partial"].contains(state.importStatus) {
            acceptReceipt(id, revision: snapshot.revision, state: state)
            return
        }
        if state.importStatus == "conflict" { throw BoostyError.resultConflict }
        if state.importStatus == "failed", state.receipt.errorCode == 422 { throw BoostyError.http(422) }
        let _: BoostyManifestAccepted = try await client.send(
            path: path + "/manifest",
            method: "PUT",
            token: credential.deviceToken,
            body: BoostyAPIClient.encoder().encode(snapshot.manifest),
        )
        state = try await client.send(path: path, token: credential.deviceToken)
        mutate(id) { $0.status = "Uploading revision \(snapshot.revision)…" }
        for descriptor in snapshot.manifest.files {
            guard let url = snapshot.files[descriptor.kind] else { throw BoostyError.invalidResponse }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var number = 1
            while let data = try handle.read(upToCount: 8 * 1024 * 1024), !data.isEmpty {
                let hash = BoostyFileHash.hex(data)
                if state.uploads?[descriptor.kind]?.parts[String(number)]?.sha256 != hash {
                    let accepted: BoostyPartAccepted = try await client.send(
                        path: path + "/files/\(descriptor.kind)/parts/\(number)?source_revision=\(snapshot.revision)",
                        method: "PUT",
                        token: credential.deviceToken,
                        body: data,
                        binary: true,
                    )
                    guard accepted.sha256 == hash else { throw BoostyError.invalidResponse }
                }
                number += 1
            }
        }
        let _: BoostyPending = try await client.send(
            path: path + "/finish",
            method: "POST",
            token: credential.deviceToken,
            body: BoostyAPIClient.encoder().encode(BoostyFinish(sourceRevision: snapshot.revision)),
        )
        mutate(id) { $0.status = "Boosty is verifying the uploaded files" }
    }

    private func acceptReceipt(_ id: UUID, revision: Int, state: BoostyRecordingState) {
        mutate(id) { draft in
            guard draft.snapshot?.revision == revision else { return }
            draft.uploadedRevision = revision
            let missing = state.receipt.completeness ?? []
            draft.status = missing.isEmpty ? "Saved in Boosty" : "Saved partially; missing: \(missing.joined(separator: ", "))"
            draft.receiptURL = state.receipt.url
            draft.botStatus = state.botStatus
        }
    }
}
