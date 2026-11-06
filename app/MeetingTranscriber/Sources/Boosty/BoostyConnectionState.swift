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
    var uploadEnabled: Bool {
        didSet { defaults.set(uploadEnabled, forKey: "boosty.uploadEnabled") }
    }

    private let defaults: UserDefaults
    private let store: BoostyCredentials
    private var connectionTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        store = BoostyCredentials(defaults: defaults)
        let loadedCredential = store.load()
        credential = loadedCredential
        origin = loadedCredential?.origin ?? defaults.string(forKey: "boosty.origin") ?? "https://meets.clientcore.ru"
        uploadEnabled = defaults.bool(forKey: "boosty.uploadEnabled")
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
            let client = try BoostyAPIClient(origin: origin)
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
                    try store.save(saved)
                    credential = saved
                    origin = client.origin
                    defaults.set(origin, forKey: "boosty.origin")
                    uploadEnabled = true
                    status = "Connected: \(saved.user.email)"
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
            let client = try BoostyAPIClient(origin: credential.origin)
            try await client.disconnect(token: credential.deviceToken)
            try store.deleteActive()
            self.credential = nil
            uploadEnabled = false
            status = "Disconnected"
        } catch {
            status = "Could not revoke the connection. \(error.localizedDescription)"
        }
    }
}
