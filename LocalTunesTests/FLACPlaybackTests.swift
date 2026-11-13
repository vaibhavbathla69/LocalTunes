import XCTest
import UIKit
@testable import LocalTunes

final class FLACPlaybackTests: XCTestCase {
    private func fixture() async throws -> (URL, LibraryPaths, LibraryDatabase, [Song]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = try LibraryPaths(documents: root.appendingPathComponent("Documents"))
        let db = try LibraryDatabase(url: paths.database)
        let urls = try (1...2).map { index in try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tone\(index)", withExtension: "flac")) }
        await ImportService(db: db, paths: paths).run(urls) { _ in }
        let songs = try await db.songs(sort: .albumTrack)
        XCTAssertEqual(songs.count, 2)
        return (root, paths, db, songs)
    }
    func testFLACImportsNativeTagsAndMeasuresDecodedSamples() async throws {
        let (root, paths, _, songs) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try XCTUnwrap(songs.first)
        XCTAssertEqual(first.title, "FLAC tone 1"); XCTAssertEqual(first.artist, "Synthetic Artist")
        XCTAssertEqual(first.album, "FLAC Album"); XCTAssertEqual(first.trackNumber, 1); XCTAssertEqual(first.discNumber, 1)
        XCTAssertEqual(first.year, 2024); XCTAssertEqual(first.duration, 4, accuracy: 0.05)
        let year = try await MetadataExtractor.readYear(paths.audioURL(for: first))
        XCTAssertEqual(year, 2024)
        let measurement = try await AudioAnalysisService.shared.measure(paths.audioURL(for: first))
        XCTAssertEqual(measurement.rms, 0.25 / sqrt(2), accuracy: 0.002)
        XCTAssertEqual(measurement.peak, 0.25, accuracy: 0.002)
        XCTAssertLessThan(measurement.gain, 1)
        XCTAssertEqual(try LibraryPaths.fingerprint(paths.audioURL(for: first)), first.fingerprint)
    }
    @MainActor
    func testNativeFLACQueueTransitionAndAccurateListeningStats() async throws {
        let (root, paths, db, songs) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackService(db: db, paths: paths)
        await player.setCrossfade(0); await player.setVolumeBalancing(false)
        await player.play(ids: songs.map(\.id))
        let reached = await waitUntil { player.currentSong?.id == songs[1].id && player.position > 2.1 }
        XCTAssertTrue(reached, player.errorMessage ?? "FLAC queue did not advance")
        XCTAssertTrue(player.isPlaying); XCTAssertFalse(player.isCrossfading)
        player.pause(); await player.flushListening()
        let report = try await db.listeningReport()
        XCTAssertEqual(report.plays, 2); XCTAssertGreaterThan(report.seconds, 5); XCTAssertLessThan(report.seconds, 8)
        try await Task.sleep(nanoseconds: 300_000_000); await player.flushListening()
        let paused = try await db.listeningReport()
        XCTAssertEqual(paused.seconds, report.seconds, accuracy: 0.02)
    }
    @MainActor
    func testCrossfadeOverlapsNextFLACAndPauseCancelsBothPlayers() async throws {
        let (root, paths, db, songs) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackService(db: db, paths: paths)
        await player.setCrossfade(1)
        await player.play(ids: songs.map(\.id))
        let faded = await waitUntil { player.isCrossfading }
        XCTAssertTrue(faded, player.errorMessage ?? "Prepared FLAC crossfade did not begin")
        XCTAssertEqual(player.currentSong?.id, songs[1].id)
        player.pause()
        XCTAssertFalse(player.isCrossfading); XCTAssertFalse(player.isPlaying)
        await player.setCrossfade(0)
    }
    @MainActor
    func testEndOfSongTimerDoesNotStartNextFLAC() async throws {
        let (root, paths, db, songs) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackService(db: db, paths: paths)
        await player.setCrossfade(0)
        await player.play(ids: songs.map(\.id))
        await player.setSleepTimer(endOfSong: true)
        let stopped = await waitUntil { !player.isPlaying && player.position >= 3.9 }
        XCTAssertTrue(stopped)
        XCTAssertEqual(player.currentSong?.id, songs[0].id)
        XCTAssertEqual(player.queue.current?.songID, songs[0].id)
        XCTAssertFalse(player.sleepTimer.isActive)
        player.pause()
    }
    @MainActor
    func testArtworkEditCreatesNewCoversAndLeavesFLACBytesUntouched() async throws {
        let (root, paths, db, songs) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let song = songs[0]
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        let model = LibraryModel(paths: paths, db: db)
        let edits = SongEdits(title: "Edited FLAC", artist: song.artist, album: song.album, genre: song.genre, track: 1, disc: 1, year: 2024, artworkPath: nil)
        try await model.updateSong(song.id, edits: edits, artwork: try XCTUnwrap(image.pngData()))
        let updated = try await db.song(song.id)
        let artwork = try XCTUnwrap(updated?.artworkPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.documents.appendingPathComponent(artwork).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.documents.appendingPathComponent(artwork.replacingOccurrences(of: ".jpg", with: ".thumb.jpg")).path))
        XCTAssertEqual(updated?.title, "Edited FLAC")
        XCTAssertEqual(try LibraryPaths.fingerprint(paths.audioURL(for: song)), song.fingerprint)
    }
    @MainActor
    func testRepeatOneCountsEachActualLoop() async throws {
        let (root, paths, db, songs) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackService(db: db, paths: paths)
        await player.setCrossfade(0)
        await player.cycleRepeat(); await player.cycleRepeat()
        await player.play(ids: [songs[0].id])
        try await Task.sleep(nanoseconds: 7_000_000_000)
        player.pause(); await player.flushListening()
        let report = try await db.listeningReport()
        XCTAssertEqual(report.plays, 2)
        XCTAssertGreaterThan(report.seconds, 5)
    }
    @MainActor
    func testBalancingCachesMeasurementWithoutChangingAudio() async throws {
        let (root, paths, db, songs) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let player = PlaybackService(db: db, paths: paths)
        await player.setVolumeBalancing(true)
        player.analyzeLibrary()
        let finished = await waitUntil { player.analysisProgress == nil }
        XCTAssertTrue(finished)
        let measurement = try await db.state("loudness.\(songs[1].fingerprint)", as: LoudnessMeasurement.self)
        XCTAssertLessThan(try XCTUnwrap(measurement).gain, 0.5)
        XCTAssertEqual(try LibraryPaths.fingerprint(paths.audioURL(for: songs[1])), songs[1].fingerprint)
        await player.setVolumeBalancing(false)
    }
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
}
