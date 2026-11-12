import Foundation
import CryptoKit

struct LibraryPaths: Sendable {
    let documents: URL
    var music: URL { documents.appendingPathComponent("Music", isDirectory: true) }
    var inbox: URL { documents.appendingPathComponent("Import", isDirectory: true) }
    var support: URL { documents.appendingPathComponent("LibraryData", isDirectory: true) }
    var artwork: URL { support.appendingPathComponent("Artwork", isDirectory: true) }
    var lyrics: URL { support.appendingPathComponent("Lyrics", isDirectory: true) }
    var staging: URL { support.appendingPathComponent("Staging", isDirectory: true) }
    var database: URL { support.appendingPathComponent("library.sqlite") }

    init(documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) throws {
        self.documents = documents
        for url in [music, inbox, support, artwork, lyrics, staging] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            // Playback must continue after the phone locks, once unlocked since boot.
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        }
        var root = documents
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }

    func audioURL(for song: Song) -> URL { documents.appendingPathComponent(song.relativePath) }
    func lyricURL(_ id: String) -> URL { lyrics.appendingPathComponent(id).appendingPathExtension("txt") }

    static func fingerprint(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sidecarKey(_ name: String) -> String {
        (name as NSString).deletingPathExtension.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
