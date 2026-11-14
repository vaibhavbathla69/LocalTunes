import Foundation
import CryptoKit

actor WiFiUploadStore {
    static let chunkSize = 1_048_576
    struct Upload: Codable, Sendable {
        var id: String
        var key: String
        var name: String
        var size: Int64
        var hashes: [String] = []
        var completed = false
        var offset: Int64 { min(size, Int64(hashes.count) * Int64(WiFiUploadStore.chunkSize)) }
    }
    private let root: URL
    private let inbox: URL
    private var cache: [String: Upload]?
    init(paths: LibraryPaths) throws {
        root = paths.support.appendingPathComponent("WiFiUploads", isDirectory: true)
        inbox = paths.inbox.appendingPathComponent("WiFi", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }
    private func manifest(_ id: String) -> URL { root.appendingPathComponent(id + ".json") }
    private func partial(_ id: String) -> URL { root.appendingPathComponent(id + ".part") }
    private func destination(_ upload: Upload) -> URL { inbox.appendingPathComponent(upload.id, isDirectory: true).appendingPathComponent(upload.name) }
    private func save(_ upload: Upload) throws { _ = try all(); try JSONEncoder().encode(upload).write(to: manifest(upload.id), options: .atomic); cache?[upload.id] = upload }
    private func load(_ id: String) throws -> Upload {
        guard UUID(uuidString: id) != nil else { throw LibraryError.message("Invalid upload ID") }
        _ = try all()
        guard let upload = cache?[id] else { throw LibraryError.message("Unknown upload") }; return upload
    }
    private func all() throws -> [Upload] {
        if let cache { return Array(cache.values) }
        let uploads = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(Upload.self, from: Data(contentsOf: $0)) }.filter { UUID(uuidString: $0.id) != nil }
        cache = Dictionary(uploads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return uploads
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func validate(_ original: Upload) throws -> Upload {
        var upload = original
        guard !upload.completed else { return upload }
        let url = partial(upload.id)
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw LibraryError.message("Invalid partial file") }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        var valid = 0
        for hash in upload.hashes {
            let expected = Int(min(Int64(Self.chunkSize), upload.size - Int64(valid) * Int64(Self.chunkSize)))
            guard let data = try handle.read(upToCount: expected), data.count == expected, Self.digest(data) == hash else { break }
            valid += 1
        }
        upload.hashes = Array(upload.hashes.prefix(valid))
        try handle.truncate(atOffset: UInt64(upload.offset))
        try save(upload)
        return upload
    }
    func begin(name: String, size: Int64, modified: String, relative: String) throws -> Upload {
        guard !name.isEmpty, name.utf8.count <= 240, !name.contains("/"), !name.contains("\\"),
              ImportService.extensions.union(["lrc", "txt"]).contains((name as NSString).pathExtension.lowercased()),
              size > 0, size <= 20 * 1_073_741_824, relative.utf8.count <= 4096, modified.count < 100 else { throw LibraryError.message("Unsupported file or size (maximum 20 GB per file)") }
        let key = Self.digest(try JSONEncoder().encode([name, String(size), modified, relative]))
        if var old = try all().first(where: { $0.key == key }) {
            if old.completed, FileManager.default.fileExists(atPath: destination(old).path) { return old }
            if old.completed { old.completed = false; old.hashes = []; try save(old); FileManager.default.createFile(atPath: partial(old.id).path, contents: nil) }
            return try validate(old)
        }
        guard try all().filter({ !$0.completed }).count < 10000 else { throw LibraryError.message("Clear transfer history before adding more files") }
        let upload = Upload(id: UUID().uuidString, key: key, name: name, size: size)
        guard FileManager.default.createFile(atPath: partial(upload.id).path, contents: nil) else { throw LibraryError.message("Cannot create upload") }
        try save(upload); return upload
    }
    func append(id: String, offset: Int64, data: Data, hash: String) throws -> Upload {
        var upload = try load(id)
        let expected = Int(min(Int64(Self.chunkSize), upload.size - upload.offset))
        guard !upload.completed, offset == upload.offset, data.count == expected, expected > 0,
              Self.digest(data) == hash.lowercased() else { throw LibraryError.message("Chunk mismatch. Select the same files again to resume.") }
        let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard capacity > Int64(data.count) + 64 * 1_048_576 else { throw LibraryError.message("Not enough free space") }
        let url = partial(id)
        guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw LibraryError.message("Invalid upload file") }
        let file = try FileHandle(forUpdating: url); defer { try? file.close() }
        guard try file.seekToEnd() == UInt64(offset) else { throw LibraryError.message("Partial file changed. Resume again.") }
        try file.write(contentsOf: data); try file.synchronize()
        upload.hashes.append(hash.lowercased()); try save(upload); return upload
    }
    func finish(id: String) throws -> URL {
        var upload = try load(id)
        if upload.completed, FileManager.default.fileExists(atPath: destination(upload).path) { return destination(upload) }
        // Recover a move that completed immediately before the process stopped.
        if !FileManager.default.fileExists(atPath: partial(id).path),
           (try? destination(upload).resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(upload.size), upload.offset == upload.size {
            upload.completed = true; try save(upload); return destination(upload)
        }
        upload = try validate(upload)
        guard upload.offset == upload.size else { throw LibraryError.message("Upload is incomplete; resume it") }
        let target = destination(upload)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw LibraryError.message("Destination already exists") }
        try FileManager.default.moveItem(at: partial(id), to: target)
        upload.completed = true; try save(upload); return target
    }
    func received() throws -> [URL] { try all().filter { $0.completed }.map { destination($0) }.filter { FileManager.default.fileExists(atPath: $0.path) } }
    func clearPartials() throws {
        for upload in try all() where !upload.completed {
            try? FileManager.default.removeItem(at: partial(upload.id)); try FileManager.default.removeItem(at: manifest(upload.id)); cache?.removeValue(forKey: upload.id)
        }
    }
}
