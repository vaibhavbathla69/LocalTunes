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

    func testSearchMatchesAllWordsWithGapsAndInAnyOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try LibraryDatabase(url: root.appendingPathComponent("db"))
        try await db.save(song("match", title: "Drugs You Should Try It"))
        try await db.save(song("only-first", title: "Drugs"))
        try await db.save(song("only-rest", title: "Should It"))
        for query in ["drugs should it", "it drugs should", "DRUGS SHO IT", "  drugs\tshould\n it  "] {
            let results = try await db.songs(search: query)
            XCTAssertEqual(results.map(\.id), ["match"], query)
            let queue = try await db.allIDs(search: query)
            XCTAssertEqual(queue, ["match"], query)
        }
        let missing = try await db.songs(search: "drugs missingword")
        XCTAssertTrue(missing.isEmpty)
        let whitespace = try await db.allIDs(search: " \t\n ")
        XCTAssertEqual(whitespace.count, 3)
    }

    func testWordSearchCombinesMetadataFiltersPaginationAndLiteralCharacters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try LibraryDatabase(url: root.appendingPathComponent("db"))
        for (id, title, year) in [("a", "Drugs You Should Try It", 2014), ("b", "Drugs Again", 2014), ("c", "Drugs Later", 2020)] {
            var value = song(id, title: title)
            value.artist = "Travis Scott"; value.album = "Days Before Rodeo"
            value.genre = "Hip Hop"; value.year = year
            try await db.save(value)
        }
        let query = "scott drugs before hip 2014"
        let filters = SearchFilters(artist: "Travis Scott", album: "Days Before Rodeo", year: 2014)
        let ids = try await db.allIDs(search: query, searchFilters: filters)
        XCTAssertEqual(ids, ["b", "a"])
        let page = try await db.songs(search: query, limit: 1, offset: 1, searchFilters: filters)
        XCTAssertEqual(page.map(\.id), ["a"])
        let wrongFilter = try await db.songs(search: query, searchFilters: SearchFilters(year: 2020))
        XCTAssertTrue(wrongFilter.isEmpty)
        let notFavourite = try await db.songs(search: query, favourite: true)
        XCTAssertTrue(notFavourite.isEmpty)
        try await db.save(song("literal", title: "100% under_score back\\slash"))
        try await db.save(song("decoy", title: "100 other underscore backslash"))
        let literal = try await db.allIDs(search: "100% under_score back\\slash")
        XCTAssertEqual(literal, ["literal"])
    }

    func testCollectionSearchMatchesWordsInAnyOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try LibraryDatabase(url: root.appendingPathComponent("db"))
        var value = song("a", title: "Song")
        value.artist = "Travis Scott"; value.album = "Days Before Rodeo"; value.genre = "Hip Hop"
        try await db.save(value)
        for (kind, query, expected) in [(LibraryGroup.album, "rodeo days", "Days Before Rodeo"), (.artist, "SCOTT TRAV", "Travis Scott"), (.genre, "hop hip", "Hip Hop")] {
            let groups = try await db.groups(kind, search: query)
            XCTAssertEqual(groups.map(\.name), [expected])
        }
        let missing = try await db.groups(.album, search: "rodeo unknown")
        XCTAssertTrue(missing.isEmpty)
    }
}
