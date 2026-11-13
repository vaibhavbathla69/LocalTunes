import XCTest
import SQLite3
@testable import LocalTunes

final class ArtistHomeTests: XCTestCase {
    private func fixture() throws -> (URL, LibraryDatabase) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, try LibraryDatabase(url: root.appendingPathComponent("library.sqlite")))
    }
    private func song(_ id: String, artist: String, title: String? = nil, album: String = "Album") -> Song {
        Song(id: id, relativePath: "Music/\(id).flac", originalFilename: "\(id).flac", fingerprint: id,
             title: title ?? id, artist: artist, album: album, genre: "Test", trackNumber: 1,
             duration: 180, byteCount: 1000, addedAt: Date())
    }
    func testCreditParsingAndUnicodeNormalizationPreserveRealNames() {
        XCTAssertEqual(ArtistCredits.names(artist: "Travis Scott feat. The Weeknd", title: "Song"), ["Travis Scott", "The Weeknd"])
        XCTAssertEqual(ArtistCredits.names(artist: "Travis Scott (ft. The Weeknd)", title: "Song (feat. The Weeknd)"), ["Travis Scott", "The Weeknd"])
        XCTAssertEqual(ArtistCredits.names(artist: "Travis Scott; The Weeknd", title: "Song"), ["Travis Scott", "The Weeknd"])
        XCTAssertEqual(ArtistCredits.names(artist: "Travis Scott", title: "Song [featuring The Weeknd & Drake]"), ["Travis Scott", "The Weeknd", "Drake"])
        XCTAssertEqual(ArtistCredits.key(" FRANK\u{00A0}  OCEAN\u{200B} "), ArtistCredits.key("Frank Ocean"))
        XCTAssertEqual(ArtistCredits.key("Ｆｒａｎｋ　Ｏｃｅａｎ"), ArtistCredits.key("Frank Ocean"))
        XCTAssertEqual(ArtistCredits.names(artist: "Tyler, the Creator", title: "Song"), ["Tyler, the Creator"])
        XCTAssertEqual(ArtistCredits.names(artist: "AC/DC", title: "Song"), ["AC/DC"])
        XCTAssertEqual(ArtistCredits.names(artist: "Earth, Wind & Fire", title: "Song"), ["Earth, Wind & Fire"])
        XCTAssertNotEqual(ArtistCredits.key("P!nk"), ArtistCredits.key("Pink"))
        var comments = Data([0, 0, 0, 0, 2, 0, 0, 0])
        for text in ["ARTIST=Travis Scott", "ARTIST=The Weeknd"] {
            var count = UInt32(text.utf8.count).littleEndian
            withUnsafeBytes(of: &count) { comments.append(contentsOf: $0) }
            comments.append(contentsOf: text.utf8)
        }
        XCTAssertEqual(FLACMetadata.commentValues(comments)["ARTIST"], ["Travis Scott", "The Weeknd"])
        XCTAssertEqual(FLACMetadata.comments(comments)["ARTIST"], "Travis Scott")
    }
    func testEveryArtistPageFilterAndQueueIncludesFeaturedSongsOnce() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await db.save(song("solo", artist: "Travis Scott"))
        try await db.save(song("collab", artist: "Travis Scott feat. The Weeknd"))
        try await db.save(song("title-credit", artist: "Travis Scott", title: "Song (feat. The Weeknd)"))
        try await db.save(song("guest-solo", artist: "The Weeknd"))
        let artists = try await db.groups(.artist)
        XCTAssertEqual(artists.count, 2)
        XCTAssertEqual(artists.first { $0.name == "Travis Scott" }?.count, 3)
        XCTAssertEqual(artists.first { $0.name == "The Weeknd" }?.count, 3)
        let primary = try await db.allIDs(group: .artist, value: "TRAVIS SCOTT")
        XCTAssertEqual(Set(primary), Set(["solo", "collab", "title-credit"]))
        let guest = try await db.allIDs(searchFilters: SearchFilters(artist: "The Weeknd"))
        XCTAssertEqual(Set(guest), Set(["collab", "title-credit", "guest-solo"]))
        let page = try await db.songs(group: .artist, value: "The Weeknd", limit: 1, offset: 1)
        XCTAssertEqual(page.map(\.id), [guest[1]])
        try await db.recordListening("collab", seconds: 180, plays: 1)
        let report = try await db.listeningReport()
        XCTAssertEqual(report.seconds, 180)
        XCTAssertEqual(report.artists.count, 2)
        XCTAssertTrue(report.artists.allSatisfy { $0.plays == 1 && $0.seconds == 180 })
        let original = try await db.song("collab")
        XCTAssertEqual(original?.artist, "Travis Scott feat. The Weeknd")
    }
    func testDuplicateNamesMergeAutomaticallyAndSpellingAliasesCanBeReset() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await db.save(song("a", artist: "FRANK OCEAN"))
        try await db.save(song("b", artist: " Frank\u{00A0} Ocean\u{200B} "))
        try await db.save(song("c", artist: "FrankOcean"))
        try await db.save(song("d", artist: "Frank Ocean; FrankOcean"))
        var artists = try await db.groups(.artist)
        XCTAssertEqual(artists.count, 2)
        XCTAssertEqual(artists.first { $0.name == "Frank Ocean" }?.count, 3)
        try await db.recordListening("d", seconds: 90, plays: 1)
        try await db.mergeArtist("FrankOcean", into: "Frank Ocean")
        artists = try await db.groups(.artist)
        XCTAssertEqual(artists.map(\.name), ["Frank Ocean"]); XCTAssertEqual(artists.first?.count, 4)
        let album = try await db.albumSummary("Album")
        XCTAssertEqual(album.artist, "Frank Ocean")
        let report = try await db.listeningReport()
        XCTAssertEqual(report.artists.first?.plays, 1, "Merging two credits on one song must not double-count it.")
        let reopened = try LibraryDatabase(url: root.appendingPathComponent("library.sqlite"))
        let resolved = try await reopened.artistDisplayName("FrankOcean")
        XCTAssertEqual(resolved, "Frank Ocean")
        _ = try await reopened.toggleFavourite("c")
        let ids = try await reopened.allIDs(group: .artist, value: "FrankOcean")
        XCTAssertEqual(Set(ids), Set(["a", "b", "c", "d"]))
        let preserved = try await reopened.song("c")
        XCTAssertEqual(preserved?.artist, "FrankOcean")
        try await reopened.resetArtistMerges()
        artists = try await reopened.groups(.artist)
        XCTAssertEqual(artists.count, 2)
    }
    func testArtistIndexBackfillsExistingCatalogWithoutChangingItsSongs() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = song("old", artist: "Travis Scott featuring The Weeknd")
        try await db.save(old); try await db.recordListening(old.id, seconds: 80, plays: 1)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("library.sqlite").path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "DELETE FROM state WHERE key='artist.index.v1'; DELETE FROM song_artists; DELETE FROM artists;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)
        let upgraded = try LibraryDatabase(url: root.appendingPathComponent("library.sqlite"))
        let artists = try await upgraded.groups(.artist)
        XCTAssertEqual(Set(artists.map(\.name)), Set(["Travis Scott", "The Weeknd"]))
        let retained = try await upgraded.song(old.id)
        XCTAssertEqual(retained, old)
        let report = try await upgraded.listeningReport()
        XCTAssertEqual(report.seconds, 80)
    }
    func testMetadataEditsUpdateMembershipAndOldPagesDisappear() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = song("a", artist: "Travis Scott", title: "Track (feat. The Weeknd)")
        try await db.save(original)
        let edit = SongEdits(title: "Track", artist: "Frank Ocean", album: "Album", genre: "Test", track: 1, disc: nil, year: nil, artworkPath: nil)
        _ = try await db.editSong("a", edits: edit)
        let artists = try await db.groups(.artist)
        XCTAssertEqual(artists.map(\.name), ["Frank Ocean"])
    }
    func testOldFLACEntriesRecoverMissingCreditsWithoutOverwritingEditsOrHistory() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = song("old", artist: "Travis Scott")
        try await db.save(old)
        _ = try await db.toggleFavourite(old.id); try await db.recordPlay(old.id)
        var tags = FLACMetadata.Tags()
        tags.values = ["TITLE": "old"]; tags.artists = ["Travis Scott", "The Weeknd"]
        let repaired = try await db.fillMissingArtistTags(old, tags: tags)
        XCTAssertEqual(repaired?.artist, "Travis Scott; The Weeknd")
        XCTAssertTrue(repaired?.isFavourite == true); XCTAssertNotNil(repaired?.lastPlayedAt)
        let guest = try await db.allIDs(group: .artist, value: "The Weeknd")
        XCTAssertEqual(guest, [old.id])
        let again = try await db.fillMissingArtistTags(old, tags: tags)
        XCTAssertNil(again)
        let manual = song("manual", artist: "Frank Ocean")
        try await db.save(manual)
        tags.values["TITLE"] = "manual"
        let retained = try await db.fillMissingArtistTags(manual, tags: tags)
        XCTAssertEqual(retained?.artist, "Frank Ocean")
        let edited = SongEdits(title: "old", artist: "Other artist", album: "Album", genre: "Test", track: 1, disc: nil, year: nil, artworkPath: nil)
        _ = try await db.editSong(old.id, edits: edited)
        let stale = try await db.fillMissingArtistTags(old, tags: tags)
        XCTAssertNil(stale)
    }
    func testHomeAlbumRanksAndLegacyLayoutMigration() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var newer = song("new", artist: "Artist", album: "Recent album"); newer.lastPlayedAt = Date()
        var popular = song("popular", artist: "Artist", album: "Popular album"); popular.lastPlayedAt = Date().addingTimeInterval(-3600)
        try await db.save(newer); try await db.save(popular)
        try await db.recordListening("new", seconds: 100, plays: 1)
        try await db.recordListening("popular", seconds: 600, plays: 4)
        let feed = try await db.homeFeed()
        XCTAssertEqual(feed.recentAlbums.map(\.name), ["Recent album", "Popular album"])
        XCTAssertEqual(feed.popularAlbums.map(\.name), ["Popular album", "Recent album"])
        XCTAssertEqual(feed.popularSongs.map(\.id), ["popular", "new"])
        XCTAssertEqual(feed.report.plays, 5); XCTAssertEqual(feed.report.seconds, 700)
        let legacy = Data(#"{"order":["shortcuts","featured","recentlyPlayed","recentlyAdded","songs"],"hidden":["featured"],"pins":[]}"#.utf8)
        let migrated = try JSONDecoder().decode(HomePreferences.self, from: legacy)
        XCTAssertEqual(migrated.order, [.recentlyPlayedAlbums, .mostPlayedAlbums, .mostPlayedSongs, .stats, .recentlyAdded])
        XCTAssertTrue(migrated.hidden.isEmpty)
        let roundTrip = try JSONDecoder().decode(HomePreferences.self, from: JSONEncoder().encode(migrated))
        XCTAssertEqual(roundTrip, migrated)
    }
}
