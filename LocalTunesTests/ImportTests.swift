import XCTest
@testable import LocalTunes

private actor ProgressRecorder {
    var last = ImportProgress()
    func accept(_ progress: ImportProgress) { last = progress }
}

final class ImportTests: XCTestCase {
    private func wav() -> Data {
        let bytes = 8820
        var data = Data()
        func text(_ string: String) { data.append(contentsOf: string.utf8) }
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + bytes)); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(44100); u32(88200); u16(2); u16(16); text("data"); u32(UInt32(bytes))
        data.append(Data(count: bytes))
        return data
    }

    func testRealImportMetadataFallbackDuplicateAndSidecar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(documents: root.appendingPathComponent("Documents"))
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let audio = source.appendingPathComponent("Untitled sample.wav")
        try wav().write(to: audio)
        try "[00:00.00]Hello".write(to: source.appendingPathComponent("Untitled sample.lrc"), atomically: true, encoding: .utf8)
        let db = try LibraryDatabase(url: paths.database)
        let importer = ImportService(db: db, paths: paths)
        let recorder = ProgressRecorder()
        await importer.run([source]) { await recorder.accept($0) }
        let first = await recorder.last
        XCTAssertTrue(first.isFinished)
        XCTAssertEqual(first.imported, 1, first.errors.joined(separator: "; "))
        XCTAssertEqual(first.attachedLyrics, 1)
        let songs = try await db.songs()
        let song = try XCTUnwrap(songs.first)
        XCTAssertEqual(song.title, "Untitled sample")
        XCTAssertEqual(song.artist, "Unknown artist")
        XCTAssertGreaterThan(song.duration, 0)
        XCTAssertEqual(try LibraryPaths.fingerprint(paths.audioURL(for: song)), song.fingerprint)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(try LyricsParser.read(paths.lyricURL(song.id)), "[00:00.00]Hello")
        await importer.run([audio]) { await recorder.accept($0) }
        let second = await recorder.last
        XCTAssertEqual(second.duplicates, 1)
        let stats = try await db.statistics()
        XCTAssertEqual(stats.count, 1)
        try FileManager.default.removeItem(at: paths.audioURL(for: song))
        await importer.run([audio]) { await recorder.accept($0) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.audioURL(for: song).path))
    }

    func testCorruptAudioLeavesNoSongOrManagedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(documents: root.appendingPathComponent("Documents"))
        let url = root.appendingPathComponent("broken.mp3")
        try Data("invalid audio".utf8).write(to: url)
        let db = try LibraryDatabase(url: paths.database)
        let recorder = ProgressRecorder()
        await ImportService(db: db, paths: paths).run([url]) { await recorder.accept($0) }
        let progress = await recorder.last
        XCTAssertEqual(progress.errors.count, 1)
        let stats = try await db.statistics()
        XCTAssertEqual(stats.count, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: paths.music.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: paths.staging.path).isEmpty)
    }
}
