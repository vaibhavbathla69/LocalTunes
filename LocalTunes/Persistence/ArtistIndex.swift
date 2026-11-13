import Foundation
import SQLite3

/// A derived many-to-many index. Original artist strings and audio files are never rewritten.
enum ArtistIndex {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func statement(_ db: OpaquePointer?, _ sql: String, _ args: [String] = []) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure(db) }
        for (i, arg) in args.enumerated() { sqlite3_bind_text(result, Int32(i + 1), arg, -1, transient) }
        return result
    }
    private static func failure(_ db: OpaquePointer?) -> Error { LibraryError.message(String(cString: sqlite3_errmsg(db))) }
    private static func run(_ db: OpaquePointer?, _ sql: String, _ args: [String] = []) throws {
        let s = try statement(db, sql, args); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw failure(db) }
    }
    private static func string(_ db: OpaquePointer?, _ sql: String, _ args: [String]) throws -> String? {
        let s = try statement(db, sql, args); defer { sqlite3_finalize(s) }
        let code = sqlite3_step(s)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw failure(db) }
        return sqlite3_column_text(s, 0).map { String(cString: $0) }
    }

    static func resolve(_ db: OpaquePointer?, _ name: String) throws -> String {
        var key = ArtistCredits.key(name), visited: Set<String> = []
        while visited.insert(key).inserted {
            guard let target = try string(db, "SELECT target_key FROM artist_aliases WHERE alias_key=?", [key]) else { return key }
            key = target
        }
        throw LibraryError.message("Artist aliases contain a cycle. Reset artist merges in Settings.")
    }

    static func rebuildIfNeeded(_ db: OpaquePointer?) throws {
        if try string(db, "SELECT key FROM state WHERE key='artist.index.v1'", []) == nil { try rebuild(db) }
    }
    static func rebuild(_ db: OpaquePointer?) throws {
        try run(db, "DELETE FROM song_artists")
        let s = try statement(db, "SELECT payload FROM songs ORDER BY added,id"); defer { sqlite3_finalize(s) }
        while true {
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let bytes = sqlite3_column_blob(s, 0) else { throw failure(db) }
            let song = try JSONDecoder().decode(Song.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, 0))))
            try update(db, song: song)
        }
        try run(db, "INSERT INTO state(key,value) VALUES('artist.index.v1','true') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
    }
    static func update(_ db: OpaquePointer?, song: Song) throws {
        try run(db, "DELETE FROM song_artists WHERE song_id=?", [song.id])
        for raw in ArtistCredits.names(artist: song.artist, title: song.title) {
            let rawKey = ArtistCredits.key(raw), key = try resolve(db, raw)
            let existing = try string(db, "SELECT name FROM artists WHERE key=?", [key])
            let name = existing.map { rawKey == key ? ArtistCredits.preferred($0, raw) : $0 } ?? raw
            try run(db, "INSERT INTO artists(key,name) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET name=excluded.name", [key, name])
            try run(db, "INSERT OR IGNORE INTO song_artists(song_id,artist_key) VALUES(?,?)", [song.id, key])
        }
    }
    static func merge(_ db: OpaquePointer?, source: String, target: String) throws {
        let sourceKey = try resolve(db, source), targetKey = try resolve(db, target)
        guard sourceKey != targetKey else { throw LibraryError.message("These names are already grouped together.") }
        guard try string(db, "SELECT key FROM artists WHERE key=?", [sourceKey]) != nil,
              try string(db, "SELECT key FROM artists WHERE key=?", [targetKey]) != nil else { throw LibraryError.message("This artist changed. Reopen the artist page.") }
        try run(db, "UPDATE artist_aliases SET target_key=? WHERE target_key=?", [targetKey, sourceKey])
        try run(db, "INSERT INTO artist_aliases(alias_key,target_key) VALUES(?,?) ON CONFLICT(alias_key) DO UPDATE SET target_key=excluded.target_key", [sourceKey, targetKey])
        try run(db, "INSERT OR IGNORE INTO song_artists(song_id,artist_key) SELECT song_id,? FROM song_artists WHERE artist_key=?", [targetKey, sourceKey])
        try run(db, "DELETE FROM song_artists WHERE artist_key=?", [sourceKey])
    }
}
