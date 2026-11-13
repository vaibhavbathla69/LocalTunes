#if DEBUG
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Synthetic test input goes through the real importer. This code is absent from Release.
enum UITestSupport {
    static func seed(paths: LibraryPaths, db: LibraryDatabase) async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("CI-input-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let albumTest = ProcessInfo.processInfo.arguments.contains("--ui-test-seed-album")
        let inputs = [("CI reference tone", 60), ("CI second tone", 30)] + (albumTest ? [("CI Zulu opener", 45)] : [])
        for (name, seconds) in inputs {
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
        guard try await db.statistics().count == inputs.count else { throw LibraryError.message("CI test input import failed.") }
        // Generated artwork exercises warm/cool palette transitions in simulator screenshots.
        for var song in try await db.songs() {
            let warm = !song.originalFilename.contains("second")
            song.artist = "LocalTunes Studio"
            song.album = warm ? "After Hours" : "Blue Hour"
            song.genre = "Electronic"
            song.trackNumber = song.originalFilename.contains("Zulu") ? 1 : (warm ? 2 : 1)
            song.discNumber = 1
            song.artworkPath = try MetadataExtractor.writeArtwork(cover(warm: warm), id: song.id, paths: paths)
            try await db.save(song)
        }
    }

    private static func cover(warm: Bool) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 800, height: 800, bitsPerComponent: 8, bytesPerRow: 3200,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw LibraryError.message("Could not create CI artwork.")
        }
        let colors = warm ? [CGColor(red: 0.98, green: 0.32, blue: 0.12, alpha: 1), CGColor(red: 0.38, green: 0.025, blue: 0.24, alpha: 1)]
                          : [CGColor(red: 0.05, green: 0.7, blue: 0.88, alpha: 1), CGColor(red: 0.1, green: 0.07, blue: 0.48, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 800, y: 800), options: [])
        }
        context.setFillColor(CGColor(red: 1, green: 0.83, blue: 0.6, alpha: 0.85))
        context.fillEllipse(in: CGRect(x: 200, y: 220, width: 400, height: 400))
        context.setBlendMode(.multiply)
        context.setFillColor(colors[1])
        for row in 0..<12 { context.fill(CGRect(x: 0, y: 100 + row * 49, width: 800, height: 16)) }
        guard let image = context.makeImage() else { throw LibraryError.message("Could not render CI artwork.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw LibraryError.message("Could not encode CI artwork.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw LibraryError.message("Could not finish CI artwork.") }
        return data as Data
    }
}
#endif
