#if DEBUG
import Foundation

/// Synthetic test input goes through the real importer. This code is absent from Release.
enum UITestSupport {
    static func seed(paths: LibraryPaths, db: LibraryDatabase) async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("CI-input-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        for (name, seconds) in [("CI reference tone", 60), ("CI second tone", 30)] {
            var data = Data()
            let size = seconds * 44100 * 2
            func text(_ value: String) { data.append(contentsOf: value.utf8) }
            func u16(_ value: UInt16) { var number = value.littleEndian; withUnsafeBytes(of: &number) { data.append(contentsOf: $0) } }
            func u32(_ value: UInt32) { var number = value.littleEndian; withUnsafeBytes(of: &number) { data.append(contentsOf: $0) } }
            text("RIFF"); u32(UInt32(36 + size)); text("WAVEfmt "); u32(16); u16(1); u16(1)
            u32(44100); u32(88200); u16(2); u16(16); text("data"); u32(UInt32(size))
            data.append(Data(count: size))
            try data.write(to: source.appendingPathComponent(name + ".wav"))
            try "[00:00.00]Music stays with you\n[00:20.00]Every word, right here\n[00:40.00]Your own collection".write(to: source.appendingPathComponent(name + ".lrc"), atomically: true, encoding: .utf8)
        }
        await ImportService(db: db, paths: paths).run([source]) { _ in }
        guard try await db.statistics().count == 2 else { throw LibraryError.message("CI test input import failed.") }
    }
}
#endif
