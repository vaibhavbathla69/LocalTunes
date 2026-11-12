import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

struct ExtractedMetadata: Sendable {
    var title: String
    var artist: String
    var album: String
    var genre: String
    var track: Int
    var duration: Double
    var artwork: Data?
    var lyrics: String?
}

enum MetadataExtractor {
    static func extract(_ url: URL, originalName: String) async throws -> ExtractedMetadata {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw LibraryError.message("This file has no playable, unprotected audio track.")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw LibraryError.message("Audio duration is invalid.") }
        var items = (try? await asset.load(.commonMetadata)) ?? []
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            items += (try? await asset.loadMetadata(for: format)) ?? []
        }
        var title: String?, artist: String?, album: String?, genre: String?, track = 0
        var artwork: Data?
        var lyrics = try? await asset.load(.lyrics)
        for item in items {
            let common = item.commonKey?.rawValue.lowercased() ?? ""
            let identifier = item.identifier?.rawValue.lowercased() ?? ""
            let key = "\(common) \(identifier)"
            if title == nil && (common == "title" || key.contains("tit2") || identifier.hasSuffix("/©nam")) { title = try? await item.load(.stringValue) }
            if artist == nil && (common == "artist" || key.contains("tpe1") || identifier.hasSuffix("/©art")) { artist = try? await item.load(.stringValue) }
            if album == nil && (common == "albumname" || key.contains("talb") || identifier.hasSuffix("/©alb")) { album = try? await item.load(.stringValue) }
            if genre == nil && (key.contains("genre") || key.contains("tcon") || identifier.hasSuffix("/©gen")) { genre = try? await item.load(.stringValue) }
            if track == 0 && (key.contains("tracknumber") || key.contains("trck") || key.contains("trkn")) {
                if let text = try? await item.load(.stringValue) { track = Int(text.split(separator: "/").first.map(String.init) ?? "") ?? 0 }
                if track == 0, let data = try? await item.load(.dataValue), data.count >= 4 { track = Int(data[2]) * 256 + Int(data[3]) }
            }
            if artwork == nil && (common == "artwork" || key.contains("apic") || key.contains("covr")) { artwork = try? await item.load(.dataValue) }
            if (lyrics ?? "").isEmpty && (key.contains("lyrics") || key.contains("uslt") || identifier.hasSuffix("/©lyr")) { lyrics = try? await item.load(.stringValue) }
        }
        return ExtractedMetadata(title: Song.text(title, fallback: Song.fallbackTitle(filename: originalName)),
                                 artist: Song.text(artist, fallback: "Unknown artist"), album: Song.text(album, fallback: "Unknown album"),
                                 genre: Song.text(genre, fallback: "Unknown genre"), track: max(0, track), duration: duration,
                                 artwork: artwork, lyrics: lyrics)
    }

    static func writeArtwork(_ data: Data, id: String, paths: LibraryPaths) throws -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        for (suffix, size) in [(".jpg", 900), (".thumb.jpg", 180)] {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceThumbnailMaxPixelSize: size,
                                          kCGImageSourceCreateThumbnailWithTransform: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
            let url = paths.artwork.appendingPathComponent(id + suffix)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw LibraryError.message("Could not save artwork. Check available storage.") }
        }
        let relative = "LibraryData/Artwork/\(id).jpg"
        return FileManager.default.fileExists(atPath: paths.documents.appendingPathComponent(relative).path) ? relative : nil
    }
}
