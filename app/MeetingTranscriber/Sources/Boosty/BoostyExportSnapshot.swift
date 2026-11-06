import CryptoKit
import Foundation

struct BoostyExportSegment: Codable, Sendable {
    let start: Double
    let end: Double
    let text: String
    let rawSpeaker: String
    var name: String
    var track: String?

    var speakerId: String {
        SHA256.hash(data: Data(((track ?? "single") + ":" + rawSpeaker).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct BoostyManifest: Codable, Sendable {
    struct Speaker: Codable, Sendable { let id: String; let name: String }
    struct Segment: Codable, Sendable { let start: Double; let end: Double; let text: String; let speakerId: String }
    struct File: Codable, Sendable { let kind: String; let size: Int; let sha256: String }
    let schemaVersion: Int
    let sourceRevision: Int
    let title: String
    let startedAt: Date
    let endedAt: Date
    let speakers: [Speaker]
    let segments: [Segment]
    let summaryMarkdown: String?
    let files: [File]
    let engines: [String: String]
    let captureWarnings: [String]
}

struct BoostyExportSnapshot: Codable, Sendable {
    let accountKey: String
    let revision: Int
    let manifest: BoostyManifest
    let files: [String: URL]
    let fingerprint: String
}

struct BoostyPendingExport: Codable, Sendable {
    let segments: [BoostyExportSegment]
    let summary: String?
    let audio: URL
}

struct BoostyUploadEntry: Codable, Sendable, Identifiable {
    let id: UUID
    let origin: String
    let accountKey: String
    let title: String
    let startedAt: Date
    var audioHostStart: Double?
    var serverRecordingId: String?
    var selectedMeetingId: String?
    var candidates: [BoostyCandidate] = []
    var skipCalendarSelection = false
    var botStatus = "Not confirmed"
    var status = "Recording"
    var video: CapturedMeetingVideo?
    var rawVideoHostStart: Double?
    var stagingStem: String?
    var warnings: [String] = []
    var snapshot: BoostyExportSnapshot?
    var pendingExport: BoostyPendingExport?
    var meetingURL: String?
    var captureStoppedAt: Date?
    var lastCaptureAt: Date?
    var stopAcknowledged: Bool? // swiftlint:disable:this discouraged_optional_boolean
    var uploadedRevision: Int?
    var nextAttempt = Date.distantPast
    var failures = 0
    var receiptURL: String?
}

enum BoostyExportPolicy {
    static func fingerprint(segments: [BoostyExportSegment], summary: String?) throws -> String {
        struct Content: Encodable { let segments: [BoostyExportSegment]; let summary: String? }
        let data = try BoostyAPIClient.encoder().encode(Content(segments: segments, summary: summary))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    struct Metadata: Sendable {
        let title: String
        let startedAt: Date
        let duration: Double
        let revision: Int
        let files: [BoostyManifest.File]
        let warnings: [String]
    }

    static func manifest(
        segments: [BoostyExportSegment], summary: String?, metadata: Metadata,
    ) throws -> BoostyManifest {
        let (title, startedAt, duration) = (metadata.title, metadata.startedAt, metadata.duration)
        guard duration.isFinite, duration > 0, duration <= 86400, !segments.isEmpty else { throw BoostyError.invalidResponse }
        var names: [String: String] = [:]
        let exported = try segments.map { segment -> BoostyManifest.Segment in
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0,
                  segment.end >= segment.start, segment.end <= duration + 0.25 else { throw BoostyError.invalidResponse }
            names[segment.speakerId] = segment.name.isEmpty ? "Speaker" : segment.name
            return .init(start: segment.start, end: segment.end, text: segment.text, speakerId: segment.speakerId)
        }
        let speakers = names.keys.sorted().map { BoostyManifest.Speaker(id: $0, name: names[$0] ?? "Speaker") }
        return BoostyManifest(
            schemaVersion: 1,
            sourceRevision: metadata.revision,
            title: title,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration),
            speakers: speakers,
            segments: exported,
            summaryMarkdown: summary,
            files: metadata.files,
            engines: ["source": "MeetingTranscriber", "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"],
            captureWarnings: metadata.warnings,
        )
    }
}
