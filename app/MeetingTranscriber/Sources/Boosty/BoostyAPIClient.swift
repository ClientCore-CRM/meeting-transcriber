import CryptoKit
import Foundation

/// Content-free failures: server response bodies may contain meeting data.
enum BoostyError: Error, LocalizedError {
    case invalidOrigin
    case http(Int)
    case invalidResponse
    case keychain(Int32)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .invalidOrigin: "Enter an HTTPS installation address without a path or credentials."
        case let .http(code): "Boosty request failed (HTTP \(code))."
        case .invalidResponse: "Boosty returned an invalid response."
        case let .keychain(code): "Could not save the Boosty connection in Keychain (\(code))."
        case .disconnected: "Connect your Boosty account in Settings."
        }
    }
}

enum BoostyPKCE {
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func make() -> (verifier: String, challenge: String) {
        let verifier = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        return (verifier, challenge(for: verifier))
    }
}

/// Credentials must never follow a redirect to another origin.
final class BoostyRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _: URLSession, task: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @Sendable (URLRequest?) -> Void,
    ) {
        guard let source = task.originalRequest?.url, let destination = request.url,
              BoostyAPIClient.sameOrigin(source, destination) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

struct BoostyAPIClient: Sendable {
    let origin: String
    private let session: URLSession

    init(origin: String, session: URLSession? = nil) throws {
        guard let components = URLComponents(string: origin), components.scheme == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let url = components.url else { throw BoostyError.invalidOrigin }
        self.origin = String(url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 120
        self.session = session ?? URLSession(configuration: configuration, delegate: BoostyRedirectGuard(), delegateQueue: nil)
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme == rhs.scheme && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? 443) == (rhs.port ?? 443)
    }

    func makeRequest(path: String, method: String, token: String? = nil, body: Data? = nil, binary: Bool = false) throws -> URLRequest {
        guard path.hasPrefix("/api/desktop/"), !path.contains(".."),
              let base = URL(string: origin), let url = URL(string: origin + path), Self.sameOrigin(url, base) else {
            throw BoostyError.invalidOrigin
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(binary ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    func send<T: Decodable & Sendable>(path: String, method: String = "GET", token: String? = nil, body: Data? = nil, binary: Bool = false) async throws -> T {
        let request = try makeRequest(path: path, method: method, token: token, body: body, binary: binary)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BoostyError.invalidResponse }
        guard (200 ..< 300).contains(response.statusCode) else { throw BoostyError.http(response.statusCode) }
        return try Self.decoder().decode(T.self, from: data)
    }

    func disconnect(token: String) async throws {
        let request = try makeRequest(path: "/api/desktop/auth/device", method: "DELETE", token: token)
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BoostyError.invalidResponse }
        guard response.statusCode == 204 || response.statusCode == 401 else { throw BoostyError.http(response.statusCode) }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw BoostyError.invalidResponse }
            return date
        }
        return decoder
    }
}
