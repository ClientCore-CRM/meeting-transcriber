import Foundation

struct BoostyUser: Codable, Sendable {
    let id: Int
    let email: String
    let name: String
}

struct BoostyConnection: Codable, Sendable {
    let requestId: String
    let connectUrl: URL
    let expiresIn: Int
    let pollInterval: Int
}

struct BoostyCredential: Codable, Sendable {
    let origin: String
    let deviceToken: String
    let deviceId: String
    let expiresAt: Date
    let user: BoostyUser

    var accountKey: String {
        origin + "#" + String(user.id)
    }
}

struct BoostyExchange: Codable, Sendable {
    let deviceToken: String
    let deviceId: String
    let expiresAt: Date
    let user: BoostyUser
}

struct BoostyReceipt: Codable, Sendable {
    let meetingId: String?
    let url: String?
    let sourceRevision: Int?
    let completeness: [String]? // swiftlint:disable:this discouraged_optional_collection
    let error: String?
    let errorCode: Int?
}

struct BoostyCandidate: Codable, Sendable, Identifiable {
    let id: String
    let title: String
    let startedAt: Date
}

struct BoostyPart: Codable, Sendable {
    let sha256: String
    let size: Int
}

struct BoostyUploadProgress: Codable, Sendable {
    let parts: [String: BoostyPart]
    let completed: Bool
    let verified: Bool
}

struct BoostyRecordingState: Codable, Sendable {
    let recordingId: String
    let clientRecordingId: String
    let meetingId: String?
    let botStatus: String
    let importStatus: String
    let sourceRevision: Int
    let receipt: BoostyReceipt
    let candidates: [BoostyCandidate]? // swiftlint:disable:this discouraged_optional_collection
    let uploads: [String: BoostyUploadProgress]? // swiftlint:disable:this discouraged_optional_collection
}

struct BoostyStart: Encodable, Sendable {
    let clientRecordingId: UUID
    let startedAt: Date
    let meetingId: String?
    let meetingUrl: String?
}

struct BoostyFinish: Encodable, Sendable { let sourceRevision: Int }
struct BoostyPending: Decodable, Sendable { let importStatus: String? }
struct BoostyPartAccepted: Decodable, Sendable { let part: Int; let sha256: String }
struct BoostyManifestAccepted: Decodable, Sendable { let sourceRevision: Int }
