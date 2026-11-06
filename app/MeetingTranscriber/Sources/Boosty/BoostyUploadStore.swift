import Foundation

struct BoostyUploadStore: Sendable {
    let root: URL
    var index: URL {
        root.appendingPathComponent("queue.json")
    }

    func load() throws -> [BoostyUploadEntry] {
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        do {
            return try BoostyAPIClient.decoder().decode([BoostyUploadEntry].self, from: Data(contentsOf: index))
        } catch {
            let backup = root.appendingPathComponent("queue.backup.json")
            return try BoostyAPIClient.decoder().decode([BoostyUploadEntry].self, from: Data(contentsOf: backup))
        }
    }

    func save(_ entries: [BoostyUploadEntry]) throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        if FileManager.default.fileExists(atPath: index.path) {
            let prior = try Data(contentsOf: index)
            try prior.write(to: root.appendingPathComponent("queue.backup.json"), options: .atomic)
        }
        let data = try BoostyAPIClient.encoder().encode(entries)
        try data.write(to: index, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
        let backup = root.appendingPathComponent("queue.backup.json")
        if FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
    }

    func directory(for id: UUID) throws -> URL {
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        return directory
    }
}
