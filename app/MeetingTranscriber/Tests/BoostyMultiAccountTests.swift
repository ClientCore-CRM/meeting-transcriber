import CryptoKit
import Foundation
@testable import MeetingTranscriber
import XCTest

private final class AccountTestSecrets: BoostySecretStorage {
    var values: [String: Data] = [:]
    func read(_ key: String) -> Data? {
        values[key]
    }

    func write(_ data: Data, for key: String) {
        values[key] = data
    }

    func remove(_ key: String) {
        values.removeValue(forKey: key)
    }
}

final class BoostyMultiAccountTests: XCTestCase {
    private func credential(_ origin: String, id: Int = 1) -> BoostyCredential {
        .init(
            origin: origin,
            deviceToken: "secret-\(origin)",
            deviceId: UUID().uuidString,
            expiresAt: .distantFuture,
            user: .init(id: id, email: "user\(id)@example.test", name: "Fixture"),
        )
    }

    private func withStore(_ body: (BoostyCredentials, UserDefaults, AccountTestSecrets) throws -> Void) throws {
        let suite = "BoostyMultiAccountTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { DefaultsSuite.remove(suite) }
        let secrets = AccountTestSecrets()
        try body(BoostyCredentials(defaults: defaults, secrets: secrets), defaults, secrets)
    }

    func testSameUserIDOnDifferentInstallationsKeepsSeparateGrantsAndBackgroundAccess() throws {
        try withStore { store, defaults, _ in
            let cc = credential("https://meets.clientcore.ru"), rr = credential("https://boosty.retailrocket.ru")
            try store.save(cc)
            try store.save(rr)
            try store.activate(accountKey: cc.accountKey)
            XCTAssertEqual(store.accounts.count, 2)
            XCTAssertEqual(store.load()?.deviceToken, cc.deviceToken)
            XCTAssertEqual(store.load(accountKey: rr.accountKey)?.deviceToken, rr.deviceToken)
            let metadata = try XCTUnwrap(defaults.data(forKey: "boosty.accounts.v1"))
            let text = try XCTUnwrap(String(data: metadata, encoding: .utf8))
            XCTAssertFalse(text.contains("secret-"))
            XCTAssertFalse(text.contains("device_token"))
            XCTAssertFalse(text.contains("device_id"))
        }
    }

    func testLegacySingleAccountMigratesWithoutReauthenticationOrLosingUploadPreference() throws {
        try withStore { store, defaults, secrets in
            let cc = credential("https://meets.clientcore.ru")
            let oldKey = SHA256.hash(data: Data(cc.accountKey.utf8)).map { String(format: "%02x", $0) }.joined()
            try secrets.write(BoostyAPIClient.encoder().encode(cc), for: oldKey)
            defaults.set(oldKey, forKey: "boosty.activeAccount")
            defaults.set(false, forKey: "boosty.uploadEnabled")
            XCTAssertEqual(store.accounts.first?.id, cc.accountKey)
            XCTAssertEqual(store.accounts.first?.uploadEnabled, false)
            try store.save(credential("https://boosty.retailrocket.ru"), makeActive: false)
            XCTAssertEqual(store.load()?.accountKey, cc.accountKey)
            XCTAssertEqual(store.accounts.count, 2)
            XCTAssertEqual(store.load(accountKey: cc.accountKey)?.deviceToken, cc.deviceToken)
        }
    }

    func testDisconnectingOneAccountNeverRevokesOrSelectsAnotherAccount() throws {
        try withStore { store, _, _ in
            let cc = credential("https://meets.clientcore.ru"), rr = credential("https://boosty.retailrocket.ru")
            try store.save(cc)
            try store.save(rr)
            try store.remove(accountKey: rr.accountKey)
            XCTAssertNil(store.load())
            XCTAssertNil(store.load(accountKey: rr.accountKey))
            XCTAssertEqual(store.load(accountKey: cc.accountKey)?.deviceToken, cc.deviceToken)
            XCTAssertEqual(store.accounts.map(\.id), [cc.accountKey])
        }
    }

    func testUploadPreferencesAreIndependentAndWrongScopedSecretIsRejected() throws {
        try withStore { store, _, secrets in
            let cc = credential("https://meets.clientcore.ru"), rr = credential("https://boosty.retailrocket.ru")
            try store.save(cc)
            try store.save(rr)
            try store.setUploadEnabled(accountKey: cc.accountKey, enabled: false)
            XCTAssertEqual(store.accounts.first { $0.id == rr.accountKey }?.uploadEnabled, true)
            let rrKey = SHA256.hash(data: Data(rr.accountKey.utf8)).map { String(format: "%02x", $0) }.joined()
            try secrets.write(BoostyAPIClient.encoder().encode(cc), for: rrKey)
            XCTAssertNil(store.load(accountKey: rr.accountKey))
        }
    }

    func testEntireLiveCaptureRetargetsWithoutRestartingLocalMediaAndSurvivesRestart() throws {
        let cc = credential("https://meets.clientcore.ru"), rr = credential("https://boosty.retailrocket.ru")
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        var entry = BoostyUploadEntry(
            id: UUID(),
            origin: cc.origin,
            accountKey: cc.accountKey,
            title: "Meeting",
            startedAt: started,
            audioHostStart: 100,
            stagingStem: "same-audio",
        )
        entry.serverRecordingId = UUID().uuidString
        entry.selectedMeetingId = "cc-calendar-id"
        entry.meetingUrl = "https://zoom.us/j/123"
        entry.rawVideoHostStart = 102
        let old = entry.route
        try entry.retarget(to: rr, at: started.addingTimeInterval(60))
        XCTAssertEqual(entry.startedAt, started)
        XCTAssertEqual(entry.id, old.clientRecordingId)
        XCTAssertEqual(entry.stagingStem, "same-audio")
        XCTAssertEqual(entry.audioHostStart, 100)
        XCTAssertEqual(entry.rawVideoHostStart, 102)
        XCTAssertEqual(entry.accountKey, rr.accountKey)
        XCTAssertNil(entry.serverRecordingId)
        XCTAssertNil(entry.selectedMeetingId)
        XCTAssertNotEqual(entry.route.clientRecordingId, old.clientRecordingId)
        XCTAssertEqual(entry.retiredCaptures?.first?.meetingId, "cc-calendar-id")
        entry.receiptUrl = "/calls/fixture"
        let encoded = try BoostyAPIClient.encoder().encode(entry)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["routing_id"], "existing snake-case wire key is preserved")
        let restored = try BoostyAPIClient.decoder().decode(BoostyUploadEntry.self, from: encoded)
        XCTAssertEqual(restored.route, entry.route)
        XCTAssertEqual(restored.meetingUrl, entry.meetingUrl)
        XCTAssertEqual(restored.receiptUrl, entry.receiptUrl)
        XCTAssertEqual(restored.retiredCaptures?.first?.meetingUrl, entry.retiredCaptures?.first?.meetingUrl)
        XCTAssertEqual(restored.retiredCaptures?.first?.route, old)
        let intermediate = entry.route
        try entry.retarget(to: cc, at: started.addingTimeInterval(90))
        XCTAssertNotEqual(entry.route.clientRecordingId, old.clientRecordingId)
        XCTAssertNotEqual(entry.route.clientRecordingId, intermediate.clientRecordingId)
    }

    func testLateOldStartResponseOnlyUpdatesRetiredRouteAndCompletedCaptureCannotMove() throws {
        let cc = credential("https://meets.clientcore.ru"), rr = credential("https://boosty.retailrocket.ru")
        var entry = BoostyUploadEntry(
            id: UUID(),
            origin: cc.origin,
            accountKey: cc.accountKey,
            title: "Meeting",
            startedAt: Date(),
            audioHostStart: nil,
        )
        let old = entry.route
        try entry.retarget(to: rr, at: Date())
        let state = BoostyRecordingState(
            recordingId: "old-server",
            clientRecordingId: old.clientRecordingId.uuidString,
            meetingId: "cc-meeting",
            botStatus: "cancelled",
            importStatus: "recording",
            sourceRevision: 0,
            receipt: .init(meetingId: nil, url: nil, sourceRevision: nil, completeness: nil, error: nil, errorCode: nil),
            candidates: nil,
            uploads: nil,
        )
        entry.acceptStart(state, for: old)
        XCTAssertNil(entry.serverRecordingId)
        XCTAssertNil(entry.selectedMeetingId)
        XCTAssertEqual(entry.retiredCaptures?.first?.serverRecordingId, "old-server")
        entry.captureStoppedAt = Date()
        XCTAssertThrowsError(try entry.retarget(to: cc, at: Date()))
        XCTAssertEqual(entry.accountKey, rr.accountKey)
    }

    func testLegacyQueueWithoutRoutingFieldsStillDecodes() throws {
        let cc = credential("https://meets.clientcore.ru")
        let entry = BoostyUploadEntry(id: UUID(), origin: cc.origin, accountKey: cc.accountKey, title: "Legacy", startedAt: Date(), audioHostStart: nil)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: BoostyAPIClient.encoder().encode(entry)) as? [String: Any])
        object.removeValue(forKey: "routing_id")
        object.removeValue(forKey: "retired_captures")
        let restored = try BoostyAPIClient.decoder().decode(BoostyUploadEntry.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.route.clientRecordingId, entry.id)
        XCTAssertNil(restored.retiredCaptures)
    }
}
