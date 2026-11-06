import Foundation
import CryptoKit
enum AppPaths {
    static let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("unused-account-check-singleton")
}
final class MemoryBoostySecrets: BoostySecretStorage {
    var values: [String: Data] = [:]
    func read(_ key: String) -> Data? { values[key] }
    func write(_ data: Data, for key: String) throws { values[key] = data }
    func remove(_ key: String) throws { values.removeValue(forKey: key) }
}
@main struct Checks {
    @MainActor static func main() async throws {
        let suite = "BoostyMultiProbe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { DefaultsSuite.remove(suite) }
        let secrets = MemoryBoostySecrets()
        let cc = BoostyCredential(origin: "https://meets.clientcore.ru", deviceToken: "secret-cc", deviceId: "cc", expiresAt: .distantFuture, user: .init(id: 1, email: "cc@example.test", name: "CC"))
        let rr = BoostyCredential(origin: "https://boosty.retailrocket.ru", deviceToken: "secret-rr", deviceId: "rr", expiresAt: .distantFuture, user: .init(id: 1, email: "rr@example.test", name: "RR"))
        let store = BoostyCredentials(defaults: defaults, secrets: secrets)
        try store.save(cc)
        try store.save(rr)
        precondition(store.accounts.count == 2)
        try store.activate(accountKey: cc.accountKey)
        precondition(store.load()?.deviceToken == "secret-cc")
        precondition(store.load(accountKey: rr.accountKey)?.deviceToken == "secret-rr")
        let encodedDefaults = String(describing: defaults.dictionaryRepresentation())
        precondition(!encodedDefaults.contains("secret-cc") && !encodedDefaults.contains("secret-rr"))
        let id = UUID(), start = Date(timeIntervalSince1970: 1700000000)
        var entry = BoostyUploadEntry(id: id, origin: cc.origin, accountKey: cc.accountKey, title: "Call", startedAt: start, audioHostStart: 12, stagingStem: "stem")
        entry.serverRecordingId = "old-server"
        entry.selectedMeetingId = "old-meeting"
        entry.meetingURL = "https://zoom.us/j/123"
        let old = entry.route
        try entry.retarget(to: rr, at: start.addingTimeInterval(120))
        precondition(entry.id == id && entry.startedAt == start && entry.stagingStem == "stem")
        precondition(entry.accountKey == rr.accountKey && entry.serverRecordingId == nil && entry.selectedMeetingId == nil)
        precondition(entry.route.clientRecordingId != old.clientRecordingId)
        precondition(entry.retiredCaptures?.first?.route.accountKey == cc.accountKey)
        let stale = BoostyRecordingState(recordingId: "late-cc", clientRecordingId: id.uuidString, meetingId: "private-cc", botStatus: "cancelled", importStatus: "recording", sourceRevision: 0, receipt: .init(meetingId: nil, url: nil, sourceRevision: nil, completeness: nil, error: nil, errorCode: nil), candidates: [], uploads: nil)
        entry.acceptStart(stale, for: old)
        precondition(entry.serverRecordingId == nil && entry.selectedMeetingId == nil)
        precondition(entry.retiredCaptures?.first?.serverRecordingId == "late-cc")
        let rrRoute = entry.route
        try entry.retarget(to: cc, at: start.addingTimeInterval(180))
        precondition(entry.route.clientRecordingId != old.clientRecordingId && entry.route.clientRecordingId != rrRoute.clientRecordingId)
        let roundTrip = try BoostyAPIClient.decoder().decode(BoostyUploadEntry.self, from: BoostyAPIClient.encoder().encode(entry))
        precondition(roundTrip.retiredCaptures?.count == 2)
        entry.captureStoppedAt = start.addingTimeInterval(200)
        do { try entry.retarget(to: rr, at: start); fatalError("retargeted finished capture") } catch {}
        try store.remove(accountKey: rr.accountKey)
        precondition(store.load(accountKey: cc.accountKey) != nil && store.load(accountKey: rr.accountKey) == nil)
        try await checkQueueIsolation(cc: cc, rr: rr)
        try await checkDelayedDisconnect(cc: cc, rr: rr)
        print("MULTI_ACCOUNT_ROUTING_CHECK_PASSED")
    }
}

/// Synthetic transport only; never opens a network connection or reads real credentials.
final class AccountFixtureNetwork: @unchecked Sendable {
    static let shared = AccountFixtureNetwork()
    private let lock = NSLock()
    private var held: [AccountFixtureURLProtocol] = []
    private var requests: [URLRequest] = []
    private var holdsCC = true
    private var heldDelete: AccountFixtureURLProtocol?
    let ccID = UUID().uuidString
    let rrID = UUID().uuidString

    var history: [URLRequest] { lock.withLock { requests } }
    var hasHeldDelete: Bool { lock.withLock { heldDelete != nil } }
    var hasHeldStart: Bool { lock.withLock { !held.isEmpty } }

    func receive(_ transport: AccountFixtureURLProtocol) {
        let request = transport.request
        let hold = lock.withLock {
            requests.append(request)
            if request.httpMethod == "DELETE" {
                heldDelete = transport
                return true
            }
            if holdsCC, request.url?.host == "meets.clientcore.ru", request.url?.path.hasSuffix("/start") == true {
                held.append(transport)
                return true
            }
            return false
        }
        if !hold { transport.finish(response(for: request)) }
    }

    func releaseDelete() {
        let pending = lock.withLock {
            let value = heldDelete
            heldDelete = nil
            return value
        }
        pending?.finish(Data(), status: 204)
    }

    func releaseStarts() {
        let pending = lock.withLock {
            holdsCC = false
            let pending = held
            held.removeAll()
            return pending
        }
        for transport in pending { transport.finish(response(for: transport.request)) }
    }

    func response(for request: URLRequest) -> Data {
        let path = request.url!.path
        let isCC = request.url!.host == "meets.clientcore.ru"
        precondition(request.value(forHTTPHeaderField: "Authorization") == (isCC ? "Bearer secret-cc" : "Bearer secret-rr"))
        if path.contains("/parts/") {
            let body = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }
                var data = Data(), bytes = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    data.append(contentsOf: bytes.prefix(count))
                }
                return data
            } ?? Data()
            return try! JSONSerialization.data(withJSONObject: ["part": 1, "sha256": BoostyFileHash.hex(body)])
        }
        if path.hasSuffix("/manifest") { return Data(#"{"source_revision":1}"#.utf8) }
        if path.hasSuffix("/finish") { return Data(#"{"import_status":"validating"}"#.utf8) }
        let candidates: [[String: Any]] = isCC ? [["id": "cc-private-candidate", "title": "CC private meeting", "started_at": "2026-11-06T10:00:00Z"]] : []
        return try! JSONSerialization.data(withJSONObject: [
            "recording_id": isCC ? ccID : rrID, "client_recording_id": UUID().uuidString,
            "bot_status": "cancelled", "import_status": "recording", "source_revision": 0,
            "receipt": [:], "candidates": candidates, "uploads": [:],
        ])
    }
}

final class AccountFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { AccountFixtureNetwork.shared.receive(self) }
    override func stopLoading() {}
    func finish(_ data: Data, status: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor private func eventually(_ predicate: () -> Bool) async throws {
    for _ in 0 ..< 400 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    preconditionFailure("Timed out waiting for account queue fixture")
}

@MainActor private func checkQueueIsolation(cc: BoostyCredential, rr: BoostyCredential) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let network = AccountFixtureNetwork.shared
    let makeClient: (String) throws -> BoostyAPIClient = { origin in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountFixtureURLProtocol.self]
        return try BoostyAPIClient(origin: origin, session: URLSession(configuration: configuration))
    }
    let queue = BoostyUploadQueue(root: directory, activeAccount: { cc }, credentialLookup: { key in
        key == cc.accountKey ? cc : key == rr.accountKey ? rr : nil
    }, makeClient: makeClient)
    queue.resume()
    let id = queue.begin(pid: nil, title: "Synthetic meeting", startedAt: Date(), stagingStem: "capture")!
    try await eventually { network.hasHeldStart }
    try queue.retargetCurrentCaptures(to: rr)
    try await eventually { queue.entries.first?.serverRecordingId == network.rrID }
    network.releaseStarts()
    try await eventually { queue.entries.first?.retiredCaptures?.isEmpty == true }
    precondition(queue.entries.first?.accountKey == rr.accountKey)
    precondition(queue.entries.first?.serverRecordingId == network.rrID)
    precondition(queue.entries.first?.candidates.isEmpty == true)
    // Durable index remembers the new account and preserves the original local capture ID.
    let recovered = try BoostyUploadStore(root: directory).load()
    precondition(recovered.first?.id == id && recovered.first?.accountKey == rr.accountKey)
    precondition(network.history.filter { $0.url?.host == "meets.clientcore.ru" }.allSatisfy {
        $0.url!.path.hasSuffix("/start") || $0.url!.path.hasSuffix("/capture-state")
    })
    queue.stopCapture(id)
    try await eventually { queue.entries.first?.stopAcknowledged == true }

    // A completed RR capture keeps uploading to RR even though the selected account source is CC.
    let audio = directory.appendingPathComponent("audio.wav")
    try Data("synthetic audio".utf8).write(to: audio)
    let file = BoostyManifest.File(kind: "audio", size: 15, sha256: "fixture")
    let manifest = BoostyManifest(schemaVersion: 1, sourceRevision: 1, title: "Synthetic meeting", startedAt: Date(), endedAt: Date(), speakers: [], segments: [], summaryMarkdown: "Summary", files: [file], engines: [:], captureWarnings: [])
    queue.mutate(id) { entry in
        entry.skipCalendarSelection = true
        entry.snapshot = .init(accountKey: rr.accountKey, revision: 1, manifest: manifest, files: ["audio": audio], fingerprint: "fixture")
    }
    queue.retry(id)
    try await eventually { network.history.contains { $0.url?.path.hasSuffix("/finish") == true } }
    precondition(network.history.filter { $0.url?.path.hasSuffix("/manifest") == true }.allSatisfy { $0.url?.host == "boosty.retailrocket.ru" })
    precondition(network.history.filter { $0.url?.host == "meets.clientcore.ru" }.allSatisfy { !$0.url!.path.contains("/files/") })
    print("LIVE_QUEUE_STALE_RESPONSE_AND_INACTIVE_UPLOAD_PASSED")
}


@MainActor private func checkDelayedDisconnect(cc: BoostyCredential, rr: BoostyCredential) async throws {
    let suite = "BoostyDisconnectProbe.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { DefaultsSuite.remove(suite) }
    let secrets = MemoryBoostySecrets()
    let store = BoostyCredentials(defaults: defaults, secrets: secrets)
    try store.save(cc)
    try store.save(rr, makeActive: false)
    let connection = BoostyConnectionState(defaults: defaults, secrets: secrets) { origin in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountFixtureURLProtocol.self]
        return try BoostyAPIClient(origin: origin, session: URLSession(configuration: configuration))
    }
    let network = AccountFixtureNetwork.shared
    let request = Task { await connection.disconnect() }
    try await eventually { network.hasHeldDelete }
    connection.selectAccount(rr.accountKey)
    network.releaseDelete()
    await request.value
    precondition(connection.credential?.accountKey == rr.accountKey, "delayed CC disconnect cleared selected RR")
    precondition(store.load(accountKey: rr.accountKey) != nil, "delayed CC disconnect deleted RR grant")
    precondition(store.load(accountKey: cc.accountKey) == nil, "revoked CC grant remained registered")
    // Reconnecting the same account while its older grant is being revoked also preserves the replacement.
    try store.save(cc)
    connection.selectAccount(cc.accountKey)
    let secondRequest = Task { await connection.disconnect() }
    try await eventually { network.hasHeldDelete }
    let replacement = BoostyCredential(origin: cc.origin, deviceToken: "replacement-cc", deviceId: "new-cc-device", expiresAt: .distantFuture, user: cc.user)
    try store.save(replacement)
    connection.selectAccount(cc.accountKey)
    network.releaseDelete()
    await secondRequest.value
    precondition(connection.credential?.deviceId == replacement.deviceId)
    precondition(store.load(accountKey: cc.accountKey)?.deviceId == replacement.deviceId)
    print("DELAYED_DISCONNECT_ACCOUNT_SCOPE_PASSED")
}
