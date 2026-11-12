import XCTest
@testable import LocalTunes

final class DatabaseTests: XCTestCase {
    private func song(_ id: String, title: String) -> Song {
        Song(id: id, relativePath: "Music/\(id).m4a", originalFilename: "\(id).m4a", fingerprint: id,
             title: title, artist: "Artist", album: "Album", genre: "Unknown genre", trackNumber: 0,
             duration: 120, byteCount: 1024, addedAt: Date())
    }

    func testIndexPaginationDuplicateAndPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try LibraryDatabase(url: root.appendingPathComponent("library.sqlite"))
        try await db.save(song("a", title: "Alpha"))
        try await db.save(song("b", title: "Beta"))
        let page = try await db.songs(limit: 1, offset: 1)
        XCTAssertEqual(page.map(\.id), ["b"])
        let match = try await db.song(fingerprint: "a")
        XCTAssertEqual(match?.title, "Alpha")
        var duplicate = song("c", title: "Copy")
        duplicate.fingerprint = "a"
        do { try await db.save(duplicate); XCTFail("Duplicate hash should be rejected") } catch { }
        let stats = try await db.statistics()
        XCTAssertEqual(stats.count, 2)
        let reopened = try LibraryDatabase(url: root.appendingPathComponent("library.sqlite"))
        let retained = try await reopened.song("a")
        XCTAssertEqual(retained?.title, "Alpha")
    }

    func testSearchTreatsWildcardCharactersLiterally() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try LibraryDatabase(url: root.appendingPathComponent("db"))
        try await db.save(song("a", title: "100%"))
        try await db.save(song("b", title: "Other"))
        let results = try await db.songs(search: "%")
        XCTAssertEqual(results.map(\.id), ["a"])
    }

    func testMetadataFallbacks() {
        XCTAssertEqual(Song.text(" \n", fallback: "Unknown artist"), "Unknown artist")
        XCTAssertEqual(Song.text("  Real title ", fallback: "Unused"), "Real title")
        XCTAssertEqual(Song.fallbackTitle(filename: "A song.mp3"), "A song")
        XCTAssertEqual(LibraryPaths.sidecarKey("CAFÉ.MP3"), LibraryPaths.sidecarKey("cafe.lrc"))
    }
}
