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
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw LibraryError.message("Could not open library database. Your files have been preserved.")
        }
        connection = db
        // Refuse unknown future schemas. Never delete a database to recover from a migration error.
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil)
        let version = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
        sqlite3_finalize(statement)
        guard version <= 2 else {
            sqlite3_close(db); connection = nil
            throw LibraryError.message("This library was created by a newer app. Install that version; the library has not been changed.")
        }
        // A consistent pre-upgrade snapshot is kept alongside the index, never audio copies.
        if version == 1 {
            do { try Self.copyDatabase(db, to: url.deletingLastPathComponent().appendingPathComponent("library-before-v2-\(UUID().uuidString).sqlite")) }
            catch { sqlite3_close(db); connection = nil; throw error }
        }
        let additions = version == 1 ? """
        ALTER TABLE songs ADD COLUMN track_number INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE songs ADD COLUMN disc_number INTEGER NOT NULL DEFAULT 1;
        ALTER TABLE songs ADD COLUMN duration_seconds REAL NOT NULL DEFAULT 0;
        ALTER TABLE songs ADD COLUMN album_order INTEGER;
        """ : ""
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA foreign_keys=ON;
        PRAGMA busy_timeout=5000;
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS songs (
          id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
          artist TEXT NOT NULL, album TEXT NOT NULL, genre TEXT NOT NULL,
          added REAL NOT NULL, played REAL, favourite INTEGER NOT NULL DEFAULT 0,
          bytes INTEGER NOT NULL, payload BLOB NOT NULL,
          track_number INTEGER NOT NULL DEFAULT 0, disc_number INTEGER NOT NULL DEFAULT 1,
          duration_seconds REAL NOT NULL DEFAULT 0, album_order INTEGER
        );
        \(additions)
        CREATE INDEX IF NOT EXISTS songs_title ON songs(title COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS songs_album ON songs(album COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS songs_artist ON songs(artist COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS songs_genre ON songs(genre COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS songs_added ON songs(added DESC);
        CREATE INDEX IF NOT EXISTS songs_played ON songs(played DESC);
        CREATE INDEX IF NOT EXISTS songs_album_order ON songs(album,album_order,disc_number,track_number);
        CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS listening (
          song_id TEXT PRIMARY KEY REFERENCES songs(id) ON DELETE CASCADE,
          seconds REAL NOT NULL DEFAULT 0, plays INTEGER NOT NULL DEFAULT 0
        );
        PRAGMA user_version=2;
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            sqlite3_close(db); connection = nil
            throw LibraryError.message("Database migration failed: \(message). Nothing was reset.")
        }
        do {
            if version == 1 { try Self.indexAlbumPositions(db) }
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw LibraryError.message(String(cString: sqlite3_errmsg(db))) }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db); connection = nil
            throw LibraryError.message("Album index migration failed: \(error.localizedDescription). Your library was not reset.")
        }
    }

    deinit { sqlite3_close(connection) }

    private static func indexAlbumPositions(_ db: OpaquePointer) throws {
        var read: OpaquePointer?, update: OpaquePointer?
        defer { sqlite3_finalize(read); sqlite3_finalize(update) }
        guard sqlite3_prepare_v2(db, "SELECT id,payload FROM songs", -1, &read, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "UPDATE songs SET track_number=?,disc_number=?,duration_seconds=? WHERE id=?", -1, &update, nil) == SQLITE_OK else {
            throw LibraryError.message(String(cString: sqlite3_errmsg(db)))
        }
        let decoder = JSONDecoder()
        while true {
            let code = sqlite3_step(read)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let blob = sqlite3_column_blob(read, 1) else { throw LibraryError.message("Cannot read an existing song during migration.") }
            let song = try decoder.decode(Song.self, from: Data(bytes: blob, count: Int(sqlite3_column_bytes(read, 1))))
            sqlite3_reset(update); sqlite3_clear_bindings(update)
            sqlite3_bind_int(update, 1, Int32(song.effectiveTrackNumber))
            sqlite3_bind_int(update, 2, Int32(song.effectiveDiscNumber))
            sqlite3_bind_double(update, 3, song.duration)
            sqlite3_bind_text(update, 4, song.id, -1, transient)
            guard sqlite3_step(update) == SQLITE_DONE else { throw LibraryError.message(String(cString: sqlite3_errmsg(db))) }
        }
    }

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
        INSERT INTO songs(id,fingerprint,title,artist,album,genre,added,played,favourite,bytes,track_number,disc_number,duration_seconds,payload)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
        fingerprint=excluded.fingerprint,title=excluded.title,artist=excluded.artist,album=excluded.album,
        genre=excluded.genre,added=excluded.added,played=excluded.played,favourite=excluded.favourite,
        bytes=excluded.bytes,track_number=excluded.track_number,disc_number=excluded.disc_number,
        duration_seconds=excluded.duration_seconds,payload=excluded.payload
        """, [song.id, song.fingerprint, song.title, song.artist, song.album, song.genre,
              String(song.addedAt.timeIntervalSince1970), song.lastPlayedAt.map { String($0.timeIntervalSince1970) } ?? "",
              song.isFavourite ? "1" : "0", String(song.byteCount), String(song.effectiveTrackNumber), String(song.effectiveDiscNumber), String(song.duration)])
        defer { sqlite3_finalize(statement) }
        if song.lastPlayedAt == nil { sqlite3_bind_null(statement, 8) }
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 14, $0.baseAddress, Int32(data.count), Self.transient) }
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
               group: LibraryGroup? = nil, value: String? = nil, limit: Int = 150, offset: Int = 0,
               searchFilters: SearchFilters = SearchFilters(), smart: SmartCollection? = nil) throws -> [Song] {
        let filter = filters(search: search, favourite: favourite, group: group, value: value, extra: searchFilters, smart: smart)
        let order = ordering(sort, group: group)
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

    private func ordering(_ sort: LibrarySort, group: LibraryGroup?) -> String {
        if sort == .albumTrack || (sort == .title && group == .album) {
            return "(album_order IS NULL),album_order,disc_number,(track_number=0),track_number,title COLLATE NOCASE,id"
        }
        switch sort {
        case .title, .albumTrack: return "title COLLATE NOCASE,id"
        case .added: return "added DESC,id"
        case .played: return "played DESC,id"
        case .mostPlayed: return "COALESCE((SELECT plays FROM listening WHERE song_id=songs.id),0) DESC,COALESCE((SELECT seconds FROM listening WHERE song_id=songs.id),0) DESC,title COLLATE NOCASE,id"
        }
    }

    func albumSummary(_ name: String) throws -> AlbumSummary {
        let statement = try prepare("SELECT COUNT(*),COALESCE(SUM(duration_seconds),0),COUNT(DISTINCT artist),MIN(artist),COALESCE(MAX(album_order IS NOT NULL),0),COALESCE(MAX(disc_number),1) FROM songs WHERE album=?", [name])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        let artist = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "Unknown artist"
        return AlbumSummary(count: Int(sqlite3_column_int(statement, 0)), duration: sqlite3_column_double(statement, 1),
                            artist: sqlite3_column_int(statement, 2) > 1 ? "Various artists" : artist,
                            hasCustomOrder: sqlite3_column_int(statement, 4) != 0, maxDisc: Int(sqlite3_column_int(statement, 5)))
    }

    func setAlbumOrder(_ name: String, songIDs: [String]) throws {
        let current = try allIDs(group: .album, value: name)
        guard Set(current) == Set(songIDs), songIDs.count == current.count, Set(songIDs).count == songIDs.count else {
            throw LibraryError.message("This album changed while you were editing it. Reopen Reorder tracks and try again.")
        }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("UPDATE songs SET album_order=NULL WHERE album=?", [name])
            for (index, id) in songIDs.enumerated() { try execute("UPDATE songs SET album_order=? WHERE id=? AND album=?", [String(index), id, name]) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func resetAlbumOrder(_ name: String) throws { try execute("UPDATE songs SET album_order=NULL WHERE album=?", [name]) }

    private func filters(search: String, favourite: Bool, group: LibraryGroup?, value: String?, extra: SearchFilters = SearchFilters(), smart: SmartCollection? = nil) -> (String, [String]) {
        var clauses = ["1=1"]
        var args: [String] = []
        if !search.isEmpty {
            clauses.append("(title LIKE ? ESCAPE '\\' OR artist LIKE ? ESCAPE '\\' OR album LIKE ? ESCAPE '\\' OR genre LIKE ? ESCAPE '\\' OR CAST(json_extract(CAST(payload AS TEXT),'$.year') AS TEXT) LIKE ? ESCAPE '\\')")
            let escaped = search.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            args += Array(repeating: "%\(escaped)%", count: 5)
        }
        if favourite { clauses.append("favourite=1") }
        if let group, let value { clauses.append("\(group.rawValue)=?"); args.append(value) }
        for (column, text) in [("artist", extra.artist), ("album", extra.album), ("genre", extra.genre)] where !text.isEmpty {
            clauses.append("\(column)=? COLLATE NOCASE"); args.append(text)
        }
        if let year = extra.year { clauses.append("json_extract(CAST(payload AS TEXT),'$.year')=CAST(? AS INTEGER)"); args.append(String(year)) }
        if let smart {
            switch smart {
            case .recentlyAdded: clauses.append("added>=?"); args.append(String(Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970))
            case .mostPlayed: clauses.append("EXISTS(SELECT 1 FROM listening WHERE song_id=songs.id AND plays>0)")
            case .forgottenFavourites:
                clauses.append("favourite=1 AND (played IS NULL OR played<?)")
                args.append(String(Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970))
            }
        }
        return (clauses.joined(separator: " AND "), args)
    }

    func allIDs(search: String = "", favourite: Bool = false, group: LibraryGroup? = nil, value: String? = nil, sort: LibrarySort = .title,
                searchFilters: SearchFilters = SearchFilters(), smart: SmartCollection? = nil) throws -> [String] {
        let filter = filters(search: search, favourite: favourite, group: group, value: value, extra: searchFilters, smart: smart)
        let order = ordering(sort, group: group)
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

    func groups(_ kind: LibraryGroup, search: String = "", searchFilters: SearchFilters = SearchFilters()) throws -> [GroupSummary] {
        let filter = filters(search: "", favourite: false, group: nil, value: nil, extra: searchFilters)
        let statement = try prepare("SELECT \(kind.rawValue),COUNT(*) FROM songs WHERE \(filter.0) GROUP BY \(kind.rawValue) ORDER BY \(kind.rawValue) COLLATE NOCASE", filter.1)
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

    func editSong(_ id: String, edits: SongEdits) throws -> Song {
        guard var current = try song(id) else { throw LibraryError.message("This song is no longer in the library.") }
        guard !edits.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (0...65535).contains(edits.track), edits.disc == nil || (1...65535).contains(edits.disc!),
              edits.year == nil || (1...9999).contains(edits.year!) else { throw LibraryError.message("Check the title, track, disc and year.") }
        let oldAlbum = current.album
        current.title = edits.title.trimmingCharacters(in: .whitespacesAndNewlines)
        current.artist = Song.text(edits.artist, fallback: "Unknown artist")
        current.album = Song.text(edits.album, fallback: "Unknown album")
        current.genre = Song.text(edits.genre, fallback: "Unknown genre")
        current.trackNumber = edits.track; current.discNumber = edits.disc; current.year = edits.year
        current.artworkPath = edits.artworkPath
        try execute("BEGIN IMMEDIATE")
        do {
            try save(current)
            if oldAlbum != current.album { try execute("UPDATE songs SET album_order=NULL WHERE id=?", [id]) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        return current
    }

    func recordListening(_ id: String, seconds: Double, plays: Int) throws {
        guard seconds.isFinite, seconds >= 0, plays >= 0, try song(id) != nil else { return }
        try execute("INSERT INTO listening(song_id,seconds,plays) VALUES(?,?,?) ON CONFLICT(song_id) DO UPDATE SET seconds=seconds+excluded.seconds,plays=plays+excluded.plays", [id, String(seconds), String(plays)])
    }

    func listeningReport() throws -> ListeningReport {
        let totals = try prepare("SELECT COALESCE(SUM(seconds),0),COALESCE(SUM(plays),0) FROM listening")
        defer { sqlite3_finalize(totals) }
        guard sqlite3_step(totals) == SQLITE_ROW else { throw error() }
        var report = ListeningReport(seconds: sqlite3_column_double(totals, 0), plays: Int(sqlite3_column_int(totals, 1)))
        for artist in [false, true] {
            let sql = artist
                ? "SELECT songs.artist,songs.artist,SUM(listening.seconds),SUM(listening.plays) FROM songs JOIN listening ON songs.id=listening.song_id GROUP BY songs.artist HAVING SUM(listening.seconds)>0 ORDER BY SUM(listening.seconds) DESC,songs.artist LIMIT 20"
                : "SELECT songs.id,songs.title,listening.seconds,listening.plays FROM songs JOIN listening ON songs.id=listening.song_id WHERE listening.seconds>0 ORDER BY listening.seconds DESC,songs.title LIMIT 20"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            var leaders: [ListeningLeader] = []
            while true {
                let code = sqlite3_step(stmt)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw error() }
                leaders.append(ListeningLeader(id: String(cString: sqlite3_column_text(stmt, 0)), title: String(cString: sqlite3_column_text(stmt, 1)), seconds: sqlite3_column_double(stmt, 2), plays: Int(sqlite3_column_int(stmt, 3))))
            }
            if artist { report.artists = leaders } else { report.songs = leaders }
        }
        return report
    }

    func clearListening() throws { try execute("DELETE FROM listening") }

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
        guard let connection else { throw LibraryError.message("The library is closed.") }
        try Self.copyDatabase(connection, to: url)
    }

    private static func copyDatabase(_ source: OpaquePointer, to url: URL) throws {
        var destination: OpaquePointer?
        guard sqlite3_open(url.path, &destination) == SQLITE_OK, let destination else {
            if let destination { sqlite3_close(destination) }
            throw LibraryError.message("Could not open backup destination.")
        }
        defer { sqlite3_close(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else { throw LibraryError.message(String(cString: sqlite3_errmsg(destination))) }
        let result = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finish == SQLITE_OK else { throw LibraryError.message("Could not create a consistent database backup.") }
    }
}
