import Foundation
import SQLite3

/// A single serial executor owns the connection. No audio blobs are stored in SQLite.
actor LibraryDatabase {
    private var connection: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw LibraryError.message("Could not open library database. Your files have been preserved.")
        }
        connection = db
        // Refuse unknown future schemas. Never delete a database to recover from a migration error.
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil)
        let version = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
        sqlite3_finalize(statement)
        guard version <= 1 else {
            sqlite3_close(db); connection = nil
            throw LibraryError.message("This library was created by a newer app. Install that version; the library has not been changed.")
        }
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA foreign_keys=ON;
        PRAGMA busy_timeout=5000;
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS songs (
          id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
          artist TEXT NOT NULL, album TEXT NOT NULL, genre TEXT NOT NULL,
          added REAL NOT NULL, played REAL, favourite INTEGER NOT NULL DEFAULT 0,
          bytes INTEGER NOT NULL, payload BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS songs_title ON songs(title COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS songs_album ON songs(album COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS songs_artist ON songs(artist COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS songs_genre ON songs(genre COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS songs_added ON songs(added DESC);
        CREATE INDEX IF NOT EXISTS songs_played ON songs(played DESC);
        CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value BLOB NOT NULL);
        PRAGMA user_version=1;
        COMMIT;
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            sqlite3_close(db); connection = nil
            throw LibraryError.message("Database migration failed: \(message). Nothing was reset.")
        }
    }

    deinit { sqlite3_close(connection) }

    private func prepare(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, Self.transient)
        }
        return statement
    }

    private func error() -> Error { LibraryError.message(String(cString: sqlite3_errmsg(connection))) }
    private func execute(_ sql: String, _ values: [String] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    func save(_ song: Song) throws {
        let data = try encoder.encode(song)
        let statement = try prepare("""
        INSERT INTO songs(id,fingerprint,title,artist,album,genre,added,played,favourite,bytes,payload)
        VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
        fingerprint=excluded.fingerprint,title=excluded.title,artist=excluded.artist,album=excluded.album,
        genre=excluded.genre,added=excluded.added,played=excluded.played,favourite=excluded.favourite,
        bytes=excluded.bytes,payload=excluded.payload
        """, [song.id, song.fingerprint, song.title, song.artist, song.album, song.genre,
              String(song.addedAt.timeIntervalSince1970), song.lastPlayedAt.map { String($0.timeIntervalSince1970) } ?? "",
              song.isFavourite ? "1" : "0", String(song.byteCount)])
        defer { sqlite3_finalize(statement) }
        if song.lastPlayedAt == nil { sqlite3_bind_null(statement, 8) }
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 11, $0.baseAddress, Int32(data.count), Self.transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    private func decodeSong(_ statement: OpaquePointer) throws -> Song {
        guard let bytes = sqlite3_column_blob(statement, 0) else { throw LibraryError.message("Missing song index data.") }
        return try decoder.decode(Song.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }

    func song(_ id: String) throws -> Song? {
        let statement = try prepare("SELECT payload FROM songs WHERE id=?", [id])
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw error() }
        return try decodeSong(statement)
    }

    func song(fingerprint: String) throws -> Song? {
        let statement = try prepare("SELECT payload FROM songs WHERE fingerprint=?", [fingerprint])
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw error() }
        return try decodeSong(statement)
    }

    func songs(search: String = "", sort: LibrarySort = .title, favourite: Bool = false,
               group: LibraryGroup? = nil, value: String? = nil, limit: Int = 150, offset: Int = 0) throws -> [Song] {
        let filter = filters(search: search, favourite: favourite, group: group, value: value)
        let order: String
        switch sort {
        case .title: order = "title COLLATE NOCASE, id"
        case .added: order = "added DESC, id"
        case .played: order = "played DESC, id"
        }
        let sql = "SELECT payload FROM songs WHERE \(filter.0) ORDER BY \(order) LIMIT ? OFFSET ?"
        let statement = try prepare(sql, filter.1 + [String(limit), String(offset)])
        defer { sqlite3_finalize(statement) }
        var result: [Song] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw error() }
            result.append(try decodeSong(statement))
        }
        return result
    }

    private func filters(search: String, favourite: Bool, group: LibraryGroup?, value: String?) -> (String, [String]) {
        var clauses = ["1=1"]
        var args: [String] = []
        if !search.isEmpty {
            clauses.append("(title LIKE ? ESCAPE '\\' OR artist LIKE ? ESCAPE '\\' OR album LIKE ? ESCAPE '\\')")
            let escaped = search.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            args += Array(repeating: "%\(escaped)%", count: 3)
        }
        if favourite { clauses.append("favourite=1") }
        if let group, let value { clauses.append("\(group.rawValue)=?"); args.append(value) }
        return (clauses.joined(separator: " AND "), args)
    }

    func allIDs(search: String = "", favourite: Bool = false, group: LibraryGroup? = nil, value: String? = nil, sort: LibrarySort = .title) throws -> [String] {
        let filter = filters(search: search, favourite: favourite, group: group, value: value)
        let order = sort == .title ? "title COLLATE NOCASE, id" : (sort == .added ? "added DESC, id" : "played DESC, id")
        let statement = try prepare("SELECT id FROM songs WHERE \(filter.0) ORDER BY \(order)", filter.1)
        defer { sqlite3_finalize(statement) }
        var ids: [String] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw error() }
            ids.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        return ids
    }

    func groups(_ kind: LibraryGroup, search: String = "") throws -> [GroupSummary] {
        let statement = try prepare("SELECT \(kind.rawValue),COUNT(*) FROM songs GROUP BY \(kind.rawValue) ORDER BY \(kind.rawValue) COLLATE NOCASE")
        defer { sqlite3_finalize(statement) }
        var result: [GroupSummary] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw error() }
            let name = String(cString: sqlite3_column_text(statement, 0))
            if search.isEmpty || name.localizedStandardContains(search) {
                result.append(GroupSummary(name: name, count: Int(sqlite3_column_int(statement, 1))))
            }
        }
        return result
    }

    func statistics() throws -> (count: Int, bytes: Int64) {
        let statement = try prepare("SELECT COUNT(*),COALESCE(SUM(bytes),0) FROM songs")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        return (Int(sqlite3_column_int(statement, 0)), sqlite3_column_int64(statement, 1))
    }

    func remove(_ id: String) throws { try execute("DELETE FROM songs WHERE id=?", [id]) }

    func toggleFavourite(_ id: String) throws -> Song? {
        guard var song = try song(id) else { return nil }
        song.isFavourite.toggle(); try save(song); return song
    }

    func recordPlay(_ id: String) throws {
        guard var song = try song(id) else { return }
        song.lastPlayedAt = Date(); try save(song)
    }

    func setState<T: Encodable>(_ key: String, value: T) throws {
        let data = try encoder.encode(value)
        let statement = try prepare("INSERT INTO state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key])
        defer { sqlite3_finalize(statement) }
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), Self.transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    func state<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        let statement = try prepare("SELECT value FROM state WHERE key=?", [key])
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW, let blob = sqlite3_column_blob(statement, 0) else { throw error() }
        return try decoder.decode(type, from: Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0))))
    }

    func savePlaybackQueue(_ queue: PlaybackQueue) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try setState("queue", value: queue)
            try setState("position.v2", value: PlaybackPosition(entryID: queue.currentID, seconds: queue.position))
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// SQLite's online backup API produces a consistent snapshot, including WAL contents.
    func backup(to url: URL) throws {
        var destination: OpaquePointer?
        guard sqlite3_open(url.path, &destination) == SQLITE_OK, let destination else {
            if let destination { sqlite3_close(destination) }
            throw LibraryError.message("Could not open backup destination.")
        }
        defer { sqlite3_close(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", connection, "main") else { throw error() }
        let result = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finish == SQLITE_OK else { throw LibraryError.message("Could not create a consistent database backup.") }
    }
}
