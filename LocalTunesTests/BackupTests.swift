import XCTest
import SQLite3
@testable import LocalTunes

final class BackupTests: XCTestCase {
    func testConsistentSnapshotIncludesWALAndQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try LibraryDatabase(url: root.appendingPathComponent("original.sqlite"))
        let song = Song(id: "a", relativePath: "Music/a.wav", originalFilename: "a.wav", fingerprint: "hash",
                        title: "A", artist: "Artist", album: "Album", genre: "Genre", trackNumber: 1,
                        duration: 10, byteCount: 100, addedAt: Date())
        try await db.save(song)
        var queue = PlaybackQueue()
        queue.replace([song.id], startAt: 0); queue.position = 4.5
        try await db.savePlaybackQueue(queue)
        let backup = root.appendingPathComponent("snapshot.sqlite")
        try await db.backup(to: backup)
        let restored = try LibraryDatabase(url: backup)
        let retained = try await restored.song(song.id)
        XCTAssertEqual(retained, song)
        let saved = try await restored.state("queue", as: PlaybackQueue.self)
        XCTAssertEqual(saved, queue)
        let position = try await restored.state("position.v2", as: PlaybackPosition.self)
        XCTAssertEqual(position?.seconds, 4.5)
        XCTAssertEqual(position?.entryID, queue.currentID)
    }

    func testUnknownSchemaIsRefusedWithoutReset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("future.sqlite")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "PRAGMA user_version=999; CREATE TABLE sentinel(value TEXT); INSERT INTO sentinel VALUES('keep');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)
        XCTAssertThrowsError(try LibraryDatabase(url: url))
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, "SELECT value FROM sentinel", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "keep")
    }
}
