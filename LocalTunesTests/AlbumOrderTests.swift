import XCTest
import SQLite3
import AVFoundation
@testable import LocalTunes

final class AlbumOrderTests: XCTestCase {
    private func song(_ id: String, title: String, track: Int, disc: Int? = nil, filename: String? = nil) -> Song {
        Song(id: id, relativePath: "Music/\(id).m4a", originalFilename: filename ?? "\(id).m4a", fingerprint: id,
             title: title, artist: "Artist", album: "Album", genre: "Genre", trackNumber: track,
             duration: 120, byteCount: 1024, addedAt: Date(), discNumber: disc)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAlbumOrderingIsNumericAndSharedByPagedListAndQueue() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try LibraryDatabase(url: root.appendingPathComponent("library.sqlite"))
        for value in [song("one", title: "Zulu", track: 1), song("two", title: "Alpha", track: 2),
                      song("ten", title: "Beta", track: 10), song("disc2", title: "Aardvark", track: 1, disc: 2),
                      song("unknown", title: "Untitled", track: 0)] { try await db.save(value) }
        let ids = try await db.allIDs(group: .album, value: "Album")
        XCTAssertEqual(ids, ["one", "two", "ten", "unknown", "disc2"])
        let page = try await db.songs(group: .album, value: "Album", limit: 2, offset: 1)
        XCTAssertEqual(page.map(\.id), ["two", "ten"])
        let summary = try await db.albumSummary("Album")
        XCTAssertEqual(summary.count, 5)
        XCTAssertEqual(summary.duration, 600)
        XCTAssertEqual(summary.maxDisc, 2)
        XCTAssertFalse(summary.hasCustomOrder)
    }

    func testCustomOrderPersistsThroughFavouriteUpdateAndCanBeReset() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let db = try LibraryDatabase(url: url)
        try await db.save(song("a", title: "A", track: 1))
        try await db.save(song("b", title: "B", track: 2))
        try await db.setAlbumOrder("Album", songIDs: ["b", "a"])
        _ = try await db.toggleFavourite("b")
        let reopened = try LibraryDatabase(url: url)
        let ids = try await reopened.allIDs(group: .album, value: "Album")
        XCTAssertEqual(ids, ["b", "a"])
        let info = try await reopened.albumSummary("Album")
        XCTAssertTrue(info.hasCustomOrder)
        do { try await reopened.setAlbumOrder("Album", songIDs: ["a"]); XCTFail("Partial/stale orders must be rejected") } catch { }
        let retained = try await reopened.allIDs(group: .album, value: "Album")
        XCTAssertEqual(retained, ids)
        try await reopened.resetAlbumOrder("Album")
        let reset = try await reopened.allIDs(group: .album, value: "Album")
        XCTAssertEqual(reset, ["a", "b"])
    }

    func testFilenameFallbackAndMetadataNumberParsing() {
        XCTAssertEqual(AlbumPosition.number("03/12"), 3)
        XCTAssertEqual(AlbumPosition.number(" 2 / 3 "), 2)
        XCTAssertNil(AlbumPosition.number("unknown"))
        XCTAssertNil(AlbumPosition.number("0"))
        XCTAssertEqual(AlbumPosition.mp4Number(Data([0, 0, 0, 12, 0, 20, 0, 0])), 12)
        XCTAssertEqual(AlbumPosition.filename("01 - Zulu.mp3").track, 1)
        XCTAssertEqual(AlbumPosition.filename("2-03 Song.m4a").disc, 2)
        XCTAssertEqual(AlbumPosition.filename("2-03 Song.m4a").track, 3)
        XCTAssertNil(AlbumPosition.filename("2024 Memories.mp3").track)
        XCTAssertEqual(song("x", title: "Title", track: 0, filename: "02 - Title.mp3").effectiveTrackNumber, 2)
    }

    func testNativeMetadataReadsID3AndMP4DiscAndTrackValues() async {
        let track = AVMutableMetadataItem()
        track.identifier = AVMetadataIdentifier(rawValue: "id3/TRCK")
        track.value = "03/12" as NSString
        let disc = AVMutableMetadataItem()
        disc.identifier = AVMetadataIdentifier(rawValue: "itsk/disk")
        disc.value = Data([0, 0, 0, 2, 0, 3, 0, 0]) as NSData
        let position = await MetadataExtractor.position(in: [track, disc], filename: "99 ignored.mp3")
        XCTAssertEqual(position.track, 3)
        XCTAssertEqual(position.disc, 2)
    }

    func testLegacyMigrationBackfillsPositionsAndPreservesPayloadAndState() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let values = [song("a", title: "Zulu", track: 1), song("b", title: "Alpha", track: 0, filename: "02 - Alpha.m4a")]
        try legacyDatabase(url, songs: values)
        let db = try LibraryDatabase(url: url)
        let ids = try await db.allIDs(group: .album, value: "Album")
        XCTAssertEqual(ids, ["a", "b"])
        let retained = try await db.song("a")
        XCTAssertEqual(retained, values[0])
        let state = try await db.state("sentinel", as: String.self)
        XCTAssertEqual(state, "keep my settings")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("library-before-v2-") && $0.hasSuffix(".sqlite") })
    }

    func testFailedMigrationRollsBackInsteadOfResettingLegacyLibrary() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        try legacyDatabase(url, songs: [song("a", title: "Keep", track: 1)])
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "UPDATE songs SET payload=x'00'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        XCTAssertThrowsError(try LibraryDatabase(url: url))
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &statement, nil)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
        sqlite3_finalize(statement)
        sqlite3_prepare_v2(raw, "SELECT COUNT(*) FROM songs WHERE id='a'", -1, &statement, nil)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
        sqlite3_finalize(statement)
    }

    private func legacyDatabase(_ url: URL, songs: [Song]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw LibraryError.message("Could not create legacy fixture") }
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE songs(id TEXT PRIMARY KEY,fingerprint TEXT NOT NULL UNIQUE,title TEXT NOT NULL,artist TEXT NOT NULL,album TEXT NOT NULL,genre TEXT NOT NULL,added REAL NOT NULL,played REAL,favourite INTEGER NOT NULL DEFAULT 0,bytes INTEGER NOT NULL,payload BLOB NOT NULL);
        CREATE TABLE state(key TEXT PRIMARY KEY,value BLOB NOT NULL);
        PRAGMA user_version=1;
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw LibraryError.message("Legacy schema failed") }
        for song in songs {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO songs VALUES(?,?,?,?,?,?,?,NULL,0,?,?)", -1, &statement, nil) == SQLITE_OK else { throw LibraryError.message("Legacy insert failed") }
            let values = [song.id, song.fingerprint, song.title, song.artist, song.album, song.genre, "0", String(song.byteCount)]
            for (index, value) in values.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            let data = try JSONEncoder().encode(song)
            _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 9, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            let result = sqlite3_step(statement); sqlite3_finalize(statement)
            guard result == SQLITE_DONE else { throw LibraryError.message("Legacy payload insert failed") }
        }
        var state: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO state VALUES('sentinel',?)", -1, &state, nil)
        defer { sqlite3_finalize(state) }
        let payload = try JSONEncoder().encode("keep my settings")
        _ = payload.withUnsafeBytes { sqlite3_bind_blob(state, 1, $0.baseAddress, Int32(payload.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        XCTAssertEqual(sqlite3_step(state), SQLITE_DONE)
    }
}
