import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class BoostyConnectionState {
    static let shared = BoostyConnectionState()
    var origin: String
    private(set) var credential: BoostyCredential?
    private(set) var status = "Not connected"
    private(set) var isConnecting = false
    var settingsRequested = false
    private(set) var accounts: [BoostyAccount] = []
    var activeAccount: BoostyAccount? {
        accounts.first { $0.id == credential?.accountKey }
    }

    var uploadEnabled: Bool {
        get { activeAccount?.uploadEnabled ?? false }
        set {
            guard let credential else { return }
            do {
                try store.setUploadEnabled(accountKey: credential.accountKey, enabled: newValue)
                accounts = store.accounts
            } catch { status = error.localizedDescription }
        }
    }

    func credential(for accountKey: String) -> BoostyCredential? {
        guard accounts.contains(where: { $0.id == accountKey && $0.uploadEnabled }) else { return nil }
        return store.load(accountKey: accountKey)
    }

    func selectAccount(_ accountKey: String) {
        do { try activate(accountKey) } catch { status = "Could not switch account: \(error.localizedDescription)" }
    }

    private func activate(_ accountKey: String) throws {
        guard let saved = store.load(accountKey: accountKey) else { throw BoostyError.disconnected }
        try BoostyUploadQueue.current?.retargetCurrentCaptures(to: saved)
        try store.activate(accountKey: accountKey)
        credential = saved
        origin = saved.origin
        accounts = store.accounts
        status = saved.expiresAt > Date() ? "Connected: \(saved.user.email)" : "Connection expired. Reconnect this account."
    }

    private let defaults: UserDefaults
    private let store: BoostyCredentials
    private let makeClient: (String) throws -> BoostyAPIClient
    private var connectionTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        secrets: any BoostySecretStorage = BoostyKeychainSecrets(),
        makeClient: @escaping (String) throws -> BoostyAPIClient = { try BoostyAPIClient(origin: $0) },
    ) {
        self.defaults = defaults
        self.makeClient = makeClient
        store = BoostyCredentials(defaults: defaults, secrets: secrets)
        let loadedCredential = store.load()
        credential = loadedCredential
        origin = loadedCredential?.origin ?? defaults.string(forKey: "boosty.origin") ?? "https://meets.clientcore.ru"
        accounts = store.accounts
        if let credential { status = "Connected: \(credential.user.email)" }
    }

    func connect() {
        connectionTask?.cancel()
        isConnecting = true
        status = "Opening browser approval…"
        connectionTask = Task { [weak self] in
            guard let self else { return }
            await performConnection()
        }
    }

    private func performConnection() async {
        defer { isConnecting = false }
        do {
            let client = try makeClient(origin)
            let pkce = BoostyPKCE.make()
            struct Start: Encodable { let challenge: String }
            let pending: BoostyConnection = try await client.send(
                path: "/api/desktop/auth/start",
                method: "POST",
                body: BoostyAPIClient.encoder().encode(Start(challenge: pkce.challenge)),
            )
            guard let base = URL(string: client.origin), BoostyAPIClient.sameOrigin(pending.connectUrl, base) else {
                throw BoostyError.invalidOrigin
            }
            guard NSWorkspace.shared.open(pending.connectUrl) else { throw BoostyError.invalidResponse }
            let deadline = Date().addingTimeInterval(min(Double(pending.expiresIn), 300))
            struct Exchange: Encodable { let requestId: String; let verifier: String }
            status = "Approve your account in the browser."
            while Date() < deadline {
                try await Task.sleep(for: .seconds(max(5, min(pending.pollInterval, 30))))
                do {
                    let result: BoostyExchange = try await client.send(
                        path: "/api/desktop/auth/exchange",
                        method: "POST",
                        body: BoostyAPIClient.encoder().encode(Exchange(
                            requestId: pending.requestId,
                            verifier: pkce.verifier,
                        )),
                    )
                    let saved = BoostyCredential(
                        origin: client.origin,
                        deviceToken: result.deviceToken,
                        deviceId: result.deviceId,
                        expiresAt: result.expiresAt,
                        user: result.user,
                    )
                    try Task.checkCancellation()
                    try store.save(saved, makeActive: false)
                    try activate(saved.accountKey)
                    defaults.set(client.origin, forKey: "boosty.origin")
                    return
                } catch BoostyError.http(428) {
                    continue
                } catch BoostyError.http(429) {
                    continue
                }
            }
            status = "Connection expired. Click Connect to try again."
        } catch is CancellationError {
            status = "Connection cancelled"
        } catch {
            status = error.localizedDescription
        }
    }

    func disconnect() async {
        connectionTask?.cancel()
        guard let credential else { return }
        do {
            let client = try makeClient(credential.origin)
            try await client.disconnect(token: credential.deviceToken)
            // Revoke/remove the captured grant, never whatever account the user selected while waiting.
            // A newer grant for this same account may also have been connected in the meantime.
            if store.load(accountKey: credential.accountKey)?.deviceId == credential.deviceId {
                try store.remove(accountKey: credential.accountKey)
            }
            accounts = store.accounts
            if self.credential?.accountKey == credential.accountKey, self.credential?.deviceId == credential.deviceId {
                self.credential = nil
                status = "Disconnected"
            }
        } catch {
            status = "Could not revoke the connection. \(error.localizedDescription)"
        }
    }
}
