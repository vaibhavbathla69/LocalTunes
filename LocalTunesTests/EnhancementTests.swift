import XCTest
@testable import LocalTunes

final class EnhancementTests: XCTestCase {
    private func fixture() throws -> (URL, LibraryPaths, LibraryDatabase) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = try LibraryPaths(documents: root)
        return (root, paths, try LibraryDatabase(url: paths.database))
    }
    private func song(_ id: String, title: String = "Title", artist: String = "Artist") -> Song {
        Song(id: id, relativePath: "Music/\(id).flac", originalFilename: "\(id).flac", fingerprint: id, title: title, artist: artist, album: "Shared title", genre: "Genre", trackNumber: 1, duration: 120, byteCount: 8, addedAt: Date())
    }
    func testStorageOnlyRemovesVerifiedManagedDuplicates() async throws {
        let (root, paths, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = paths.inbox.appendingPathComponent("original.flac")
        try Data("original".utf8).write(to: original)
        var value = song("a"); value.fingerprint = try LibraryPaths.fingerprint(original)
        try Data("original".utf8).write(to: paths.audioURL(for: value)); try await db.save(value)
        let unimported = paths.inbox.appendingPathComponent("unimported.flac")
        try Data("new song".utf8).write(to: unimported)
        let service = StorageService(paths: paths, db: db)
        let usage = try await service.inspect()
        XCTAssertEqual(usage.verified, [original]); XCTAssertEqual(usage.reclaimable, 8)
        let count = try await service.removeVerified(usage.verified)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.audioURL(for: value).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unimported.path))
    }
    func testStorageRechecksChangedFilesAndRejectsOutsideImport() async throws {
        let (root, paths, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = paths.inbox.appendingPathComponent("original.flac")
        try Data("original".utf8).write(to: original)
        var value = song("a"); value.fingerprint = try LibraryPaths.fingerprint(original)
        try Data("original".utf8).write(to: paths.audioURL(for: value)); try await db.save(value)
        let service = StorageService(paths: paths, db: db)
        let usage = try await service.inspect()
        try Data("different".utf8).write(to: original)
        let count = try await service.removeVerified(usage.verified + [paths.audioURL(for: value)])
        XCTAssertEqual(count, 0); XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testAlbumIdentitySeparatesArtistsAndReleasesAndSurvivesReopen() async throws {
        let (root, paths, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var a = song("a", artist: "First"); a.year = 2000
        var b = song("b", artist: "Second"); b.year = 2000
        var c = song("c", artist: "First"); c.year = 2020
        for value in [a, b, c] { try await db.save(value) }
        let albums = try await db.groups(.album)
        XCTAssertEqual(albums.count, 3)
        let specific = try await db.allIDs(group: .album, value: AlbumIdentity.key(for: b))
        XCTAssertEqual(specific, ["b"])
        let reopened = try LibraryDatabase(url: paths.database)
        let retained = try await reopened.groups(.album)
        XCTAssertEqual(Set(retained.map(\.value)), Set(albums.map(\.value)))
        XCTAssertEqual(AlbumIdentity.title(AlbumIdentity.key(for: a)), a.album)
    }
    func testCompilationAlbumArtistKeepsGuestTracksTogether() async throws {
        let (root, _, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var a = song("a", artist: "First"); a.albumArtist = "Various Artists"
        var b = song("b", artist: "Second"); b.albumArtist = "Various Artists"
        try await db.save(a); try await db.save(b)
        let groups = try await db.groups(.album)
        XCTAssertEqual(groups.count, 1); XCTAssertEqual(groups.first?.count, 2)
    }
    func testAccentSearchRankingQueueAndTypoSuggestions() async throws {
        let (root, _, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await db.save(song("exact", title: "Café"))
        try await db.save(song("partial", title: "Cafe live"))
        try await db.save(song("artist", title: "A different song", artist: "Cafe"))
        let matches = try await db.songs(search: "cafe")
        let ids = try await db.allIDs(search: "cafe")
        XCTAssertEqual(matches.map(\.id), ["exact", "partial", "artist"]); XCTAssertEqual(ids, matches.map(\.id))
        let suggestions = try await db.searchSuggestions("caff")
        XCTAssertTrue(suggestions.contains("Café"))
    }
    func testDatedListeningPreservesTotalsAndClearsTogether() async throws {
        let (root, _, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await db.save(song("a")); try await db.recordListening("a", seconds: 80, plays: 1)
        let today = Calendar.current.startOfDay(for: Date())
        let current = try await db.listeningReport(since: today)
        let total = try await db.listeningReport()
        XCTAssertEqual(current.seconds, 80); XCTAssertEqual(total.seconds, 80)
        let days = try await db.listeningDays(); XCTAssertEqual(days, [today])
        try await db.clearListening()
        let empty = try await db.listeningReport(since: today); XCTAssertEqual(empty.plays, 0)
        let emptyDays = try await db.listeningDays(); XCTAssertTrue(emptyDays.isEmpty)
    }
    func testBulkArtworkPreservesHistoryAndRejectsChangedMembership() async throws {
        let (root, _, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var a = song("a"); a.isFavourite = true
        try await db.save(a); try await db.recordListening("a", seconds: 90, plays: 1)
        let updated = try await db.setAlbumArtwork(AlbumIdentity.key(for: a), paths: ["a": "LibraryData/Artwork/new.jpg"])
        XCTAssertTrue(updated[0].isFavourite)
        let report = try await db.listeningReport(); XCTAssertEqual(report.seconds, 90)
        do { _ = try await db.setAlbumArtwork(AlbumIdentity.key(for: a), paths: [:]); XCTFail("Reject stale album membership") } catch { }
    }
}
