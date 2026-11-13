import XCTest
@testable import LocalTunes

final class DiscoveryTests: XCTestCase {
    private func fixture() throws -> (URL, LibraryDatabase) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, try LibraryDatabase(url: root.appendingPathComponent("db")))
    }
    private func song(_ id: String) -> Song {
        Song(id: id, relativePath: "Music/\(id).flac", originalFilename: "\(id).flac", fingerprint: id,
             title: id, artist: "Artist", album: "Album", genre: "Jazz", trackNumber: 1,
             duration: 120, byteCount: 1000, addedAt: Date(), year: 2024)
    }
    func testCombinedFiltersAndQueueUseIdenticalResults() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var other = song("other"); other.year = 2023; other.genre = "Rock"
        try await db.save(song("one")); try await db.save(song("two")); try await db.save(other)
        let filters = SearchFilters(artist: "artist", album: "Album", genre: "Jazz", year: 2024)
        let page = try await db.songs(limit: 1, offset: 1, searchFilters: filters)
        let ids = try await db.allIDs(searchFilters: filters)
        XCTAssertEqual(ids, ["one", "two"]); XCTAssertEqual(page.map(\.id), ["two"])
        let yearQuery = try await db.allIDs(search: "2023")
        XCTAssertEqual(yearQuery, ["other"])
        let groups = try await db.groups(.genre, searchFilters: filters)
        XCTAssertEqual(groups.map(\.name), ["Jazz"])
    }
    func testSmartCollectionsAndListeningAggregateSurviveReopen() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var forgotten = song("forgotten"); forgotten.addedAt = Date().addingTimeInterval(-60 * 86400); forgotten.isFavourite = true
        var recentFavourite = song("recentFavourite"); recentFavourite.isFavourite = true; recentFavourite.lastPlayedAt = Date()
        for value in [song("new"), forgotten, recentFavourite] { try await db.save(value) }
        try await db.recordListening("new", seconds: 65, plays: 2)
        try await db.recordListening("new", seconds: 35, plays: 1)
        try await db.recordListening("recentFavourite", seconds: 300, plays: 1)
        let recent = try await db.allIDs(smart: .recentlyAdded)
        XCTAssertEqual(Set(recent), Set(["new", "recentFavourite"]))
        let old = try await db.allIDs(smart: .forgottenFavourites)
        XCTAssertEqual(old, ["forgotten"])
        let most = try await db.allIDs(sort: .mostPlayed, smart: .mostPlayed)
        XCTAssertEqual(most, ["new", "recentFavourite"])
        let reopened = try LibraryDatabase(url: root.appendingPathComponent("db"))
        let report = try await reopened.listeningReport()
        XCTAssertEqual(report.plays, 4); XCTAssertEqual(report.seconds, 400)
        XCTAssertEqual(report.artists.first?.title, "Artist"); XCTAssertEqual(report.artists.first?.seconds, 400)
        try await reopened.remove("recentFavourite")
        let afterDelete = try await reopened.listeningReport()
        XCTAssertEqual(afterDelete.seconds, 100)
        try await reopened.clearListening()
        let cleared = try await reopened.listeningReport()
        XCTAssertEqual(cleared.plays, 0); XCTAssertEqual(cleared.seconds, 0)
    }
    func testEditingPreservesHistoryFavouriteAndAlbumOrder() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var first = song("one"); first.lastPlayedAt = Date(); first.isFavourite = true
        try await db.save(first); try await db.save(song("two"))
        try await db.setAlbumOrder("Album", songIDs: ["two", "one"])
        try await db.recordListening("one", seconds: 100, plays: 1)
        let edits = SongEdits(title: "New title", artist: "New artist", album: "Album", genre: "Soul", track: 3, disc: 2, year: 1999, artworkPath: nil)
        let updated = try await db.editSong("one", edits: edits)
        XCTAssertTrue(updated.isFavourite); XCTAssertEqual(updated.lastPlayedAt, first.lastPlayedAt)
        XCTAssertEqual(updated.fingerprint, first.fingerprint); XCTAssertEqual(updated.relativePath, first.relativePath)
        let unchanged = try await db.fillMissingYear("one", year: 2020)
        XCTAssertNil(unchanged, "Reading years must never overwrite an existing edit.")
        let order = try await db.allIDs(group: .album, value: "Album")
        XCTAssertEqual(order, ["two", "one"])
        let search = try await db.allIDs(searchFilters: SearchFilters(year: 1999))
        XCTAssertEqual(search, ["one"])
        let report = try await db.listeningReport()
        XCTAssertEqual(report.artists.first?.title, "New artist")
        var moving = edits; moving.album = "Other"
        _ = try await db.editSong("one", edits: moving)
        let album = try await db.albumSummary("Other")
        XCTAssertFalse(album.hasCustomOrder)
    }
    @MainActor
    func testHomeAndSearchPreferencesPersistAndDeduplicate() async throws {
        let (root, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(documents: root.appendingPathComponent("Documents"))
        let model = LibraryModel(paths: paths, db: db)
        var home = HomePreferences(); home.order.reverse(); home.hidden = [.mostPlayedSongs]
        await model.saveHome(home)
        await model.togglePin(HomePin(kind: .album, value: "Album"))
        await model.rememberSearch(" Test "); await model.rememberSearch("test")
        XCTAssertEqual(model.recentSearches, ["test"])
        for index in 0..<20 { await model.rememberSearch("Query \(index)") }
        XCTAssertEqual(model.recentSearches.count, 12)
        let reloaded = LibraryModel(paths: paths, db: db); await reloaded.load()
        XCTAssertEqual(reloaded.home.hidden, [.mostPlayedSongs]); XCTAssertEqual(reloaded.home.order, home.order + [.pinned])
        XCTAssertEqual(reloaded.home.pins, [HomePin(kind: .album, value: "Album")])
        XCTAssertEqual(reloaded.recentSearches, model.recentSearches)
        await reloaded.clearSearches()
        let saved = try await db.state("search.history", as: [String].self)
        XCTAssertEqual(saved, [])
    }
    func testSleepTimerDeadlinesAndTrackIdentity() {
        let now = Date()
        XCTAssertFalse(SleepTimerState().expired(at: now, currentEntry: nil))
        let timer = SleepTimerState(deadline: now.addingTimeInterval(60))
        XCTAssertFalse(timer.expired(at: now, currentEntry: "a"))
        XCTAssertTrue(timer.expired(at: now.addingTimeInterval(61), currentEntry: "b"))
        let end = SleepTimerState(entryID: "entry-a")
        XCTAssertFalse(end.expired(at: now, currentEntry: "entry-a"))
        XCTAssertTrue(end.expired(at: now, currentEntry: "entry-b"))
    }
    func testLoudnessOnlyAttenuatesAndHandlesSilence() {
        XCTAssertEqual(LoudnessMeasurement(rms: 0, peak: 0).gain, 1)
        XCTAssertEqual(LoudnessMeasurement(rms: 0.05, peak: 0.5).gain, 1)
        XCTAssertEqual(LoudnessMeasurement(rms: 0.5, peak: 0.8).gain, 0.2, accuracy: 0.001)
        XCTAssertEqual(LoudnessMeasurement(rms: .nan, peak: 1).gain, 1)
    }
    func testMalformedFLACCommentsAreBounded() {
        XCTAssertTrue(FLACMetadata.comments(Data([255,255,255,255])).isEmpty)
        XCTAssertNil(FLACMetadata.picture(Data(count: 8)))
    }
}
