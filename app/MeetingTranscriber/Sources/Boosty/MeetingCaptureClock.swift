import Foundation

struct MeetingWindowCandidate: Sendable {
    let id: UInt32
    let pid: Int32
    let title: String
}

enum MeetingWindowSelection {
    static func continues(expected: MeetingWindowCandidate, current: MeetingWindowCandidate?) -> Bool {
        guard let current else { return false }
        return !expected.title.isEmpty && current.id == expected.id && current.pid == expected.pid && current.title == expected.title
    }

    static func automatic(_ windows: [MeetingWindowCandidate], pid: Int32, title: String) -> UInt32? {
        let owned = windows.filter { $0.pid == pid }
        let exact = owned.filter { $0.title == title }
        if exact.count == 1 { return exact[0].id }
        return owned.count == 1 ? owned[0].id : nil
    }
}

/// Host-clock arithmetic shared by capture and media assembly; never wall-clock
/// subtraction for audiovisual alignment.
enum MeetingCaptureClock {
    struct Layout: Equatable, Sendable {
        let offset: Double
        let sourceStart: Double
        let duration: Double
    }

    static func audioOrigin(app: Double?, mic: Double?, appLoaded: Bool, micLoaded: Bool) -> Double? {
        [appLoaded ? app : nil, micLoaded ? mic : nil].compactMap(\.self).min()
    }

    static func layout(videoStart: Double, audioStart: Double, videoDuration: Double, audioDuration: Double) -> Layout {
        let delta = videoStart - audioStart
        let offset = max(0, delta)
        let sourceStart = max(0, -delta)
        return Layout(
            offset: offset,
            sourceStart: sourceStart,
            duration: max(0, min(videoDuration - sourceStart, audioDuration - offset)),
        )
    }
}

enum BoostyUploadPolicy {
    static func waitForValidation(serverRevision: Int, status: String, desiredRevision: Int) -> Bool {
        // Any in-flight revision owns the server row until verification completes.
        status == "validating" && serverRevision <= desiredRevision
    }
}
