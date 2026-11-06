import Foundation

struct BoostyCaptureRoute: Codable, Equatable, Sendable {
    let clientRecordingId: UUID
    let origin: String
    let accountKey: String
}

/// Only metadata is retained for closing an earlier account's capture. No export is sent there.
struct BoostyRetiredCapture: Codable, Sendable, Identifiable {
    var id: UUID {
        route.clientRecordingId
    }

    let route: BoostyCaptureRoute
    var serverRecordingId: String?
    let meetingId: String?
    let meetingURL: String?
    let startedAt: Date
    let stoppedAt: Date
}

extension BoostyUploadEntry {
    var route: BoostyCaptureRoute {
        .init(clientRecordingId: routingID ?? id, origin: origin, accountKey: accountKey)
    }

    mutating func retarget(to credential: BoostyCredential, at date: Date) throws {
        guard captureStoppedAt == nil, snapshot == nil, pendingExport == nil else { throw BoostyError.resultConflict }
        guard credential.accountKey != accountKey else { return }
        var retired = retiredCaptures ?? []
        retired.append(.init(
            route: route,
            serverRecordingId: serverRecordingId,
            meetingId: selectedMeetingId,
            meetingURL: meetingURL,
            startedAt: startedAt,
            stoppedAt: date,
        ))
        retiredCaptures = retired
        routingID = UUID()
        origin = credential.origin
        accountKey = credential.accountKey
        serverRecordingId = nil
        selectedMeetingId = nil
        candidates = []
        skipCalendarSelection = false
        stopAcknowledged = nil
        uploadedRevision = nil
        receiptURL = nil
        failures = 0
        nextAttempt = .distantPast
        botStatus = "Cancelling bot in the selected account…"
        status = "Recording"
    }

    mutating func acceptStart(_ state: BoostyRecordingState, for requestedRoute: BoostyCaptureRoute) {
        if route == requestedRoute {
            serverRecordingId = state.recordingId
            botStatus = state.botStatus
            candidates = state.candidates ?? []
        } else if let index = retiredCaptures?.firstIndex(where: { $0.route == requestedRoute }) {
            retiredCaptures?[index].serverRecordingId = state.recordingId
        }
    }
}
