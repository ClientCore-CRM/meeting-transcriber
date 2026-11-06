import Foundation
@testable import MeetingTranscriber
import XCTest

private final class DisconnectTestSecrets: BoostySecretStorage {
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

private final class HeldRevoke: @unchecked Sendable {
    static let shared = HeldRevoke()
    private let lock = NSLock()
    private var transport: DisconnectTestURLProtocol?
    var pending: Bool {
        lock.withLock { transport != nil }
    }

    func hold(_ value: DisconnectTestURLProtocol) {
        lock.withLock { transport = value }
    }

    func release() {
        let value = lock.withLock {
            let value = transport
            transport = nil
            return value
        }
        value?.complete()
    }
}

private final class DisconnectTestURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        HeldRevoke.shared.hold(self)
    }

    override func stopLoading() {}
    func complete() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class BoostyAccountDisconnectTests: XCTestCase {
    func testLateDisconnectPreservesSelectedAccountAndNewGrantForSameAccount() async throws {
        let suite = "BoostyAccountDisconnectTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { DefaultsSuite.remove(suite) }
        let secrets = DisconnectTestSecrets()
        let store = BoostyCredentials(defaults: defaults, secrets: secrets)
        let user = BoostyUser(id: 1, email: "fixture@example.test", name: "Fixture")
        let cc = BoostyCredential(origin: "https://meets.clientcore.ru", deviceToken: "cc-token", deviceId: "cc-old", expiresAt: .distantFuture, user: user)
        let rr = BoostyCredential(
            origin: "https://boosty.retailrocket.ru",
            deviceToken: "rr-token",
            deviceId: "rr-device",
            expiresAt: .distantFuture,
            user: user,
        )
        try store.save(cc)
        try store.save(rr, makeActive: false)
        let connection = BoostyConnectionState(defaults: defaults, secrets: secrets) { origin in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DisconnectTestURLProtocol.self]
            return try BoostyAPIClient(origin: origin, session: URLSession(configuration: configuration))
        }

        let first = Task { await connection.disconnect() }
        await waitFor(HeldRevoke.shared.pending, timeout: .seconds(2))
        guard HeldRevoke.shared.pending else { first.cancel(); XCTFail("DELETE was not issued"); return }
        connection.selectAccount(rr.accountKey)
        HeldRevoke.shared.release()
        await first.value
        XCTAssertEqual(connection.credential?.accountKey, rr.accountKey)
        XCTAssertEqual(store.load(accountKey: rr.accountKey)?.deviceId, rr.deviceId)
        XCTAssertNil(store.load(accountKey: cc.accountKey))

        try store.save(cc)
        connection.selectAccount(cc.accountKey)
        let second = Task { await connection.disconnect() }
        await waitFor(HeldRevoke.shared.pending, timeout: .seconds(2))
        guard HeldRevoke.shared.pending else { second.cancel(); XCTFail("Second DELETE was not issued"); return }
        let renewed = BoostyCredential(origin: cc.origin, deviceToken: "cc-new-token", deviceId: "cc-new", expiresAt: .distantFuture, user: user)
        try store.save(renewed)
        connection.selectAccount(cc.accountKey)
        HeldRevoke.shared.release()
        await second.value
        XCTAssertEqual(connection.credential?.deviceId, renewed.deviceId)
        XCTAssertEqual(store.load(accountKey: cc.accountKey)?.deviceId, renewed.deviceId)
    }
}
