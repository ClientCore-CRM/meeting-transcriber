@preconcurrency import AVFoundation
import CryptoKit
import Foundation

/// Runs off the main actor. The immutable snapshot owns copies of its media, so
/// a later rename, queue eviction or naming cleanup cannot break an upload.
enum BoostyExportBuilder {
    static func checksum(_ url: URL) throws -> (size: Int, hash: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var size = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            digest.update(data: chunk)
            size += chunk.count
        }
        return (size, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func build(
        entry: BoostyUploadEntry,
        segments: [BoostyExportSegment],
        summary: String?,
        audio: URL,
        destination: (revision: Int, directory: URL),
    ) async throws -> BoostyExportSnapshot {
        let (revision, directory) = destination
        let audioCopy = directory.appendingPathComponent("audio-\(revision).wav")
        if !FileManager.default.fileExists(atPath: audioCopy.path) {
            let staged = directory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.copyItem(at: audio, to: staged)
            try FileManager.default.moveItem(at: staged, to: audioCopy)
        }
        let duration = try await AVURLAsset(url: audioCopy).load(.duration).seconds
        var files = ["audio": audioCopy]
        var warnings = entry.warnings
        if let captured = entry.video, let audioHostStart = entry.audioHostStart {
            do {
                let assembled = directory.appendingPathComponent("video-\(revision).mp4")
                if !FileManager.default.fileExists(atPath: assembled.path) {
                    let staged = directory.appendingPathComponent(UUID().uuidString + ".mp4")
                    defer { try? FileManager.default.removeItem(at: staged) }
                    _ = try await MeetingMediaAssembler.assemble(
                        video: captured,
                        audio: audioCopy,
                        audioHostStart: audioHostStart,
                        output: staged,
                    )
                    try FileManager.default.moveItem(at: staged, to: assembled)
                }
                files["video"] = assembled
                warnings += captured.warnings
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                warnings.append("Meeting-window video could not be assembled; processed results and audio were preserved.")
            }
        } else if entry.video != nil {
            warnings.append("Recovered audio has no verified capture clock; video was omitted to preserve transcript timing.")
        }
        let descriptors = try descriptors(for: files)
        let manifest = try BoostyExportPolicy.manifest(
            segments: segments,
            summary: summary,
            metadata: .init(
                title: entry.title,
                startedAt: entry.startedAt,
                duration: duration,
                revision: revision,
                files: descriptors,
                warnings: Array(Set(warnings)).sorted(),
            ),
        )
        return try BoostyExportSnapshot(
            accountKey: entry.accountKey,
            revision: revision,
            manifest: manifest,
            files: files,
            fingerprint: BoostyExportPolicy.fingerprint(segments: segments, summary: summary),
        )
    }

    private static func descriptors(for files: [String: URL]) throws -> [BoostyManifest.File] {
        var descriptors: [BoostyManifest.File] = []
        for kind in files.keys.sorted() {
            guard let file = files[kind] else { throw BoostyError.invalidResponse }
            let result = try checksum(file)
            guard result.size <= 4 * 1024 * 1024 * 1024 else { throw BoostyError.http(413) }
            descriptors.append(.init(kind: kind, size: result.size, sha256: result.hash))
        }
        return descriptors
    }
}
