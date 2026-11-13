import XCTest
@testable import LocalTunes

final class PlaybackTests: XCTestCase {
    private func fixture() async throws -> (URL, LibraryPaths, LibraryDatabase, Song) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = try LibraryPaths(documents: root.appendingPathComponent("Documents"))
        let db = try LibraryDatabase(url: paths.database)
        let url = root.appendingPathComponent("Silence.wav")
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(88236); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(44100); u32(88200); u16(2); u16(16); text("data"); u32(88200)
        data.append(Data(count: 88200))
        try data.write(to: url)
        await ImportService(db: db, paths: paths).run([url]) { _ in }
        let songs = try await db.songs()
        return (root, paths, db, try XCTUnwrap(songs.first))
    }

    @MainActor
    func testRestoreIsPausedAndRetainsIdentityAndPosition() async throws {
        let (root, paths, db, song) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var queue = PlaybackQueue()
        queue.replace([song.id, song.id], startAt: 1); queue.position = 0.4
        try await db.savePlaybackQueue(queue)
        let player = PlaybackService(db: db, paths: paths)
        await player.restore()
        XCTAssertEqual(player.currentSong?.id, song.id)
        XCTAssertEqual(player.queue.currentID, queue.currentID)
        XCTAssertEqual(player.position, 0.4, accuracy: 0.05)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.errorMessage)
        player.pause()
    }

    @MainActor
    func testOneToggleRestartsAfterLastSongFinishes() async throws {
        let (root, paths, db, song) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackService(db: db, paths: paths)
        await player.play(ids: [song.id])
        let ended = await waitUntil { !player.isPlaying && player.position >= song.duration - 0.02 }
        XCTAssertTrue(ended, player.errorMessage ?? "The real player did not reach the end.")
        await player.toggle()
        let restarted = await waitUntil { player.isPlaying }
        XCTAssertTrue(restarted, player.errorMessage ?? "One toggle should restart playback.")
        XCTAssertLessThan(player.position, song.duration)
        player.pause()
    }

    @MainActor
    func testAlbumPlayUsesNumericOrderAndTurnsOffPreviousShuffle() async throws {
        let (root, paths, db, original) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var first = original
        first.id = "first"; first.fingerprint = "first"; first.album = "Ordered album"; first.title = "Zulu"; first.trackNumber = 1
        var second = original
        second.id = "second"; second.fingerprint = "second"; second.album = "Ordered album"; second.title = "Alpha"; second.trackNumber = 2
        try await db.save(second); try await db.save(first)
        let model = LibraryModel(paths: paths, db: db)
        await model.player.toggleShuffle()
        XCTAssertTrue(model.player.queue.shuffle)
        await model.playAlbum("Ordered album")
        XCTAssertFalse(model.player.queue.shuffle)
        XCTAssertEqual(model.player.queue.entries.map(\.songID), ["first", "second"])
        XCTAssertEqual(model.player.currentSong?.id, "first")
        XCTAssertNil(model.player.errorMessage)
        model.player.pause()
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
}
