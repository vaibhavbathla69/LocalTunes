import Foundation

struct StorageUsage: Sendable {
    var music: Int64 = 0
    var originals: Int64 = 0
    var artwork: Int64 = 0
    var library: Int64 = 0
    var reclaimable: Int64 = 0
    var verified: [URL] = []
}

/// Cleanup is confined to Import. A file is eligible only if its complete hash
/// matches both an indexed song and an independently verified managed copy.
actor StorageService {
    private let paths: LibraryPaths
    private let db: LibraryDatabase
    init(paths: LibraryPaths, db: LibraryDatabase) { self.paths = paths; self.db = db }

    private func files(_ root: URL) -> [URL] {
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for case let url as URL in iterator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if values.isRegularFile == true { result.append(url) }
        }
        return result
    }
    private func bytes(_ urls: [URL]) -> Int64 {
        urls.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    private func inside(_ url: URL, root: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
    }
    private func managedCopy(for source: URL) async throws -> URL? {
        guard inside(source, root: paths.inbox), ImportService.extensions.contains(source.pathExtension.lowercased()) else { return nil }
        let hash = try LibraryPaths.fingerprint(source)
        guard let song = try await db.song(fingerprint: hash) else { return nil }
        let destination = paths.audioURL(for: song)
        guard inside(destination, root: paths.music), try LibraryPaths.fingerprint(destination) == hash else { return nil }
        return destination
    }
    func inspect() async throws -> StorageUsage {
        let originals = files(paths.inbox)
        var usage = StorageUsage(music: bytes(files(paths.music)), originals: bytes(originals), artwork: bytes(files(paths.artwork)), library: bytes(files(paths.support)))
        usage.library -= usage.artwork
        for source in originals {
            try Task.checkCancellation()
            if (try? await managedCopy(for: source)) != nil {
                usage.verified.append(source)
                usage.reclaimable += bytes([source])
            }
        }
        return usage
    }
    func removeVerified(_ sources: [URL]) async throws -> Int {
        var removed = 0
        for source in sources {
            try Task.checkCancellation()
            guard let destination = try await managedCopy(for: source) else { continue }
            var coordinationError: NSError?
            var operationError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: source, options: .forDeleting, error: &coordinationError) { coordinated in
                do {
                    // Recheck inside coordination: a review may have been open
                    // while Files changed the original or the managed copy.
                    guard inside(coordinated, root: paths.inbox), inside(destination, root: paths.music),
                          try LibraryPaths.fingerprint(coordinated) == LibraryPaths.fingerprint(destination) else { return }
                    try FileManager.default.removeItem(at: coordinated)
                    removed += 1
                } catch { operationError = error }
            }
            if let error = coordinationError ?? (operationError as NSError?) { throw error }
        }
        return removed
    }
}
