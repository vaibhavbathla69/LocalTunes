import Foundation
import CryptoKit
import OSLog

struct ImportProgress: Sendable {
    var completed = 0
    var total = 0
    var filename = "Preparing import…"
    var fileFraction: Double = 0
    var imported = 0
    var duplicates = 0
    var attachedLyrics = 0
    var errors: [String] = []
    var cancelled = false
    var isFinished = false
}

actor ImportService {
    let db: LibraryDatabase
    let paths: LibraryPaths
    private let logger = Logger(subsystem: "LocalTunes", category: "Import")
    private var running = false
    static let extensions: Set<String> = ["mp3", "m4a", "m4b", "m4r", "aac", "wav", "wave", "aif", "aiff", "aifc", "alac", "caf", "mp4", "flac", "au", "snd", "ac3", "amr"]

    init(db: LibraryDatabase, paths: LibraryPaths) { self.db = db; self.paths = paths }

    func run(_ roots: [URL], progress: @escaping @Sendable (ImportProgress) async -> Void) async {
        guard !running else { return }
        running = true
        defer { running = false }
        var state = ImportProgress()
        let accessed = roots.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        var candidates: [URL] = []
        var lyricFiles: [URL] = []
        var visited = Set<String>()
        func collect(_ url: URL) {
            guard visited.insert(url.standardizedFileURL.path).inserted else { return }
            let ext = url.pathExtension.lowercased()
            if Self.extensions.contains(ext) { candidates.append(url) }
            else if ext == "lrc" || ext == "txt" { lyricFiles.append(url) }
        }
        for root in roots {
            do {
                let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    var enumerationErrors: [String] = []
                    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                        if enumerationErrors.count < 100 { enumerationErrors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                        return true
                    }) else { throw LibraryError.message("Could not open folder.") }
                    while let url = enumerator.nextObject() as? URL {
                        if Task.isCancelled { break }
                        let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        if resource.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                        if resource.isRegularFile == true { collect(url) }
                    }
                    state.errors.append(contentsOf: enumerationErrors.prefix(max(0, 100 - state.errors.count)))
                } else {
                    collect(root)
                    // Sibling access may be refused by a file provider; folder import is the reliable alternative.
                    let sidecar = root.deletingPathExtension().appendingPathExtension("lrc")
                    if FileManager.default.fileExists(atPath: sidecar.path) { collect(sidecar) }
                }
            } catch { state.errors.append("\(root.lastPathComponent): \(error.localizedDescription)") }
        }
        state.total = candidates.count + lyricFiles.count
        if Task.isCancelled { state.cancelled = true }
        await progress(state)
        for source in candidates {
            if Task.isCancelled { state.cancelled = true; break }
            state.filename = source.lastPathComponent; state.fileFraction = 0
            await progress(state)
            do {
                let outcome = try await importAudio(source) { fraction in
                    var update = state; update.fileFraction = fraction
                    await progress(update)
                }
                if outcome { state.imported += 1 } else { state.duplicates += 1 }
            } catch is CancellationError { state.cancelled = true; break }
            catch {
                logger.error("Import failed: \(error.localizedDescription, privacy: .public)")
                if state.errors.count < 100 { state.errors.append("\(source.lastPathComponent): \(error.localizedDescription)") }
            }
            state.completed += 1
            state.fileFraction = 1
            await progress(state)
        }
        if !state.cancelled && !lyricFiles.isEmpty {
            // Index only names and IDs, never audio; disambiguate equal basenames using source folder metadata.
            let ids: [String]
            do { ids = try await db.allIDs() }
            catch { state.errors.append("Lyric matching index: \(error.localizedDescription)"); state.isFinished = true; await progress(state); return }
            var matches: [String: [Song]] = [:]
            for id in ids {
                if let song = try? await db.song(id) {
                    for key in Set([LibraryPaths.sidecarKey(song.originalFilename), LibraryPaths.sidecarKey(song.title), LibraryPaths.sidecarKey("\(song.artist) - \(song.title)")]) {
                        matches[key, default: []].append(song)
                    }
                }
            }
            for url in lyricFiles {
                if Task.isCancelled { state.cancelled = true; break }
                state.filename = url.lastPathComponent
                do {
                    let raw = try LyricsParser.read(url)
                    let matching = matches[LibraryPaths.sidecarKey(url.lastPathComponent)] ?? []
                    guard !matching.isEmpty else { throw LibraryError.message("No song matched this lyric filename. Attach it from Now Playing → Lyrics.") }
                    guard matching.count == 1, let song = matching.first else { throw LibraryError.message("More than one song matched. Attach these lyrics manually to choose the song.") }
                    // Manual edits win over future automatic imports.
                    let manual = try await db.state("manualLyrics.\(song.id)", as: Bool.self) ?? false
                    if !manual {
                        try raw.write(to: paths.lyricURL(song.id), atomically: true, encoding: .utf8)
                        state.attachedLyrics += 1
                    }
                } catch { if state.errors.count < 100 { state.errors.append("\(url.lastPathComponent): \(error.localizedDescription)") } }
                state.completed += 1; await progress(state)
            }
        }
        if state.total == 0 && state.errors.isEmpty { state.errors.append("No supported audio or lyric files were found.") }
        state.isFinished = true
        await progress(state)
    }

    private func importAudio(_ source: URL, progress: (Double) async -> Void) async throws -> Bool {
        let fm = FileManager.default
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let capacity = try paths.documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard capacity > Int64(size) + 64 * 1_048_576 else { throw LibraryError.message("Not enough free storage. Keep at least 64 MB free after copying this file.") }
        let id = UUID().uuidString
        let stage = paths.staging.appendingPathComponent(id).appendingPathExtension(source.pathExtension.lowercased())
        defer { try? fm.removeItem(at: stage) }
        guard fm.createFile(atPath: stage.path, contents: nil) else { throw LibraryError.message("Could not create an import file.") }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: stage)
        defer { try? input.close(); try? output.close() }
        var hash = SHA256(), copied: Int64 = 0
        var lastReport: Int64 = 0
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
            hash.update(data: chunk); copied += Int64(chunk.count)
            if copied - lastReport >= 8_388_608 {
                await progress(size > 0 ? Double(copied) / Double(size) : 0)
                lastReport = copied
            }
        }
        try output.synchronize(); try output.close(); try input.close()
        let fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
        if let existing = try await db.song(fingerprint: fingerprint) {
            if !fm.fileExists(atPath: paths.audioURL(for: existing).path) { try fm.moveItem(at: stage, to: paths.audioURL(for: existing)) }
            return false
        }
        let metadata = try await MetadataExtractor.extract(stage, originalName: source.lastPathComponent)
        try Task.checkCancellation()
        let destination = paths.music.appendingPathComponent(id).appendingPathExtension(source.pathExtension.lowercased())
        var committed = false
        defer {
            if !committed {
                try? fm.removeItem(at: destination)
                try? fm.removeItem(at: paths.artwork.appendingPathComponent(id + ".jpg"))
                try? fm.removeItem(at: paths.artwork.appendingPathComponent(id + ".thumb.jpg"))
                try? fm.removeItem(at: paths.lyricURL(id))
            }
        }
        let art = try metadata.artwork.flatMap { try MetadataExtractor.writeArtwork($0, id: id, paths: paths) }
        if let lyrics = metadata.lyrics, !lyrics.isEmpty { try lyrics.write(to: paths.lyricURL(id), atomically: true, encoding: .utf8) }
        try fm.moveItem(at: stage, to: destination)
        let song = Song(id: id, relativePath: "Music/\(destination.lastPathComponent)", originalFilename: source.lastPathComponent,
                        fingerprint: fingerprint, title: metadata.title, artist: metadata.artist, album: metadata.album,
                        genre: metadata.genre, trackNumber: metadata.track, duration: metadata.duration, byteCount: copied,
                        artworkPath: art, addedAt: Date())
        try await db.save(song)
        committed = true
        return true
    }
}
