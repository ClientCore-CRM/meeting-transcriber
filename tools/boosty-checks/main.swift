@preconcurrency import AVFoundation
import Foundation

final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override final class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override final class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Data(
            #"{"device_token":"fixture-token","device_id":"fixture-device","expires_at":"2027-01-01T10:00:00.123456+00:00","user":{"id":1,"email":"fixture@example.test","name":"Fixture"}}"#
                .utf8,
        )
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
struct BoostyChecks {
    static func main() async throws {
        do {
            _ = try BoostyAPIClient(origin: "http://meets.clientcore.ru")
            fatalError("HTTP installation accepted")
        } catch {}
        do {
            _ = try BoostyAPIClient(origin: "https://user:secret@meets.clientcore.ru")
            fatalError("Credentials in installation accepted")
        } catch {}
        let client = try BoostyAPIClient(origin: "https://meets.clientcore.ru/")
        precondition(client.origin == "https://meets.clientcore.ru")
        let pkce = BoostyPKCE.make()
        precondition(pkce.verifier.count >= 43 && pkce.challenge.count == 43)
        precondition(pkce.challenge == BoostyPKCE.challenge(for: pkce.verifier))
        let request = try client.makeRequest(path: "/api/desktop/recordings/start", method: "POST", token: "test")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test")
        precondition(request.url?.host == "meets.clientcore.ru")
        precondition(!BoostyAPIClient.sameOrigin(URL(string: "https://evil.example")!, URL(string: client.origin)!))
        let windows = [
            MeetingWindowCandidate(id: 1, pid: 10, title: "Meeting"),
            MeetingWindowCandidate(id: 2, pid: 10, title: "Chat"),
            MeetingWindowCandidate(id: 3, pid: 20, title: "Meeting"),
        ]
        precondition(MeetingWindowSelection.automatic(windows, pid: 10, title: "Meeting") == 1)
        precondition(MeetingWindowSelection.automatic(windows, pid: 10, title: "Unknown") == nil)
        precondition(MeetingWindowSelection.automatic(windows, pid: 99, title: "Meeting") == nil)
        let timing = MeetingCaptureClock.layout(videoStart: 12, audioStart: 10, videoDuration: 8, audioDuration: 10)
        precondition(timing.offset == 2 && timing.sourceStart == 0 && timing.duration == 8)
        let earlier = MeetingCaptureClock.layout(videoStart: 8, audioStart: 10, videoDuration: 12, audioDuration: 10)
        precondition(earlier.offset == 0 && earlier.sourceStart == 2 && earlier.duration == 10)
        let segments = [
            BoostyExportSegment(start: 0, end: 1, text: "Hello", rawSpeaker: "SPEAKER_0", name: "Alex", track: "app"),
            BoostyExportSegment(start: 1, end: 2, text: "Hi", rawSpeaker: "SPEAKER_0", name: "Alex", track: "mic"),
        ]
        let manifest = try BoostyExportPolicy.manifest(
            segments: segments,
            summary: "Summary",
            metadata: .init(title: "Call",
            startedAt: Date(),
            duration: 3,
            revision: 1,
            files: [],
            warnings: []),
        )
        precondition(manifest.speakers.count == 2, "Equal human names must not merge speaker identities")
        precondition(manifest.segments[0].start == 0 && manifest.segments[1].end == 2)
        let json = try BoostyAPIClient.encoder().encode(manifest)
        let fields = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        precondition(fields["source_revision"] as? Int == 1)
        precondition(fields["summary_markdown"] as? String == "Summary")
        let firstFingerprint = try BoostyExportPolicy.fingerprint(segments: segments, summary: "Summary")
        let secondFingerprint = try BoostyExportPolicy.fingerprint(segments: segments, summary: "Summary")
        precondition(firstFingerprint == secondFingerprint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let fixtureClient = try BoostyAPIClient(origin: client.origin, session: session)
        let exchange: BoostyExchange = try await fixtureClient.send(path: "/api/desktop/auth/exchange", method: "POST", body: Data("{}".utf8))
        precondition(exchange.user.id == 1 && exchange.deviceToken == "fixture-token")
        let redirected = URLRequest(url: URL(string: "https://evil.example/")!)
        let task = session.dataTask(with: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let allowed: URLRequest? = await withCheckedContinuation { continuation in
            BoostyRedirectGuard().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) {
                continuation.resume(returning: $0)
            }
        }
        precondition(allowed == nil, "A foreign origin received a credentialed redirect")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boosty-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BoostyUploadStore(root: directory.appendingPathComponent("queue"))
        var entry = BoostyUploadEntry(id: UUID(), origin: client.origin, accountKey: "fixture-account", title: "Fixture", startedAt: Date(), audioHostStart: 10)
        entry.pendingExport = .init(segments: segments, summary: "Summary", audio: directory.appendingPathComponent("audio.wav"))
        try store.save([entry])
        let restored = try store.load()
        precondition(restored.first?.pendingExport?.segments.count == 2)
        precondition(restored.first?.accountKey == entry.accountKey)
        func ffmpeg(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["ffmpeg", "-v", "error"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0)
        }
        let raw = directory.appendingPathComponent("window.mp4")
        let audio = directory.appendingPathComponent("audio.wav")
        try ffmpeg(["-f", "lavfi", "-i", "color=blue:s=160x90:r=5:d=3", "-c:v", "libx264", raw.path])
        try ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=4", audio.path])
        let captured = CapturedMeetingVideo(path: raw, hostStart: 11, duration: 3, warnings: [])
        entry.video = captured
        let snapshot = try await BoostyExportBuilder.build(
            entry: entry,
            segments: segments,
            summary: "Summary",
            audio: audio,
            destination: (revision: 1, directory: directory),
        )
        precondition(snapshot.manifest.files.count == 2)
        let outputDuration = try await AVURLAsset(url: snapshot.files["video"]!).load(.duration).seconds
        precondition(abs(outputDuration - 4) < 0.2, "Media assembly changed the original audio timeline")
        let contract = try BoostyAPIClient.encoder().encode(snapshot.manifest)
        try contract.write(to: URL(fileURLWithPath: "/private/tmp/boosty-export-contract.json"), options: .atomic)
        print("Boosty checks passed: HTTPS, PKCE, redirect isolation, API decoding, speaker identities, durable queue and actual MP4 assembly")
    }
}
