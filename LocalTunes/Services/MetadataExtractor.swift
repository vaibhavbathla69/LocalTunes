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
    var disc: Int?
    var duration: Double
    var artwork: Data?
    var lyrics: String?
    var year: Int? = nil
}

enum MetadataExtractor {
    static func readFLACArtistTags(_ url: URL) async throws -> FLACMetadata.Tags? {
        try FLACMetadata.read(url, includeArtwork: false)
    }
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
        var title: String?, artist: String?, album: String?, genre: String?
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
            if artwork == nil && (common == "artwork" || key.contains("apic") || key.contains("covr")) { artwork = try? await item.load(.dataValue) }
            if (lyrics ?? "").isEmpty && (key.contains("lyrics") || key.contains("uslt") || identifier.hasSuffix("/©lyr")) { lyrics = try? await item.load(.stringValue) }
        }
        let flac = try? FLACMetadata.read(url)
        if let flac {
            title = flac["TITLE"] ?? title
            artist = flac.artists.isEmpty ? (flac["ARTIST"] ?? artist) : flac.artists.joined(separator: "; ")
            album = flac["ALBUM"] ?? album; genre = flac["GENRE"] ?? genre
            artwork = flac.picture ?? artwork; lyrics = flac["LYRICS"] ?? flac["UNSYNCEDLYRICS"] ?? lyrics
        }
        var year = flac?.year
        if year == nil {
            for item in items {
                let key = "\(item.commonKey?.rawValue ?? "") \(item.identifier?.rawValue ?? "")".lowercased()
                if key.contains("creationdate") || key.contains("tdrc") || key.contains("tyer") || key.contains("day") {
                    if let date = try? await item.load(.stringValue), let parsed = Int(date.prefix(4)) { year = parsed; break }
                }
            }
        }
        let position = await position(in: items, filename: originalName)
        return ExtractedMetadata(title: Song.text(title, fallback: Song.fallbackTitle(filename: originalName)),
                                 artist: Song.text(artist, fallback: "Unknown artist"), album: Song.text(album, fallback: "Unknown album"),
                                 genre: Song.text(genre, fallback: "Unknown genre"), track: AlbumPosition.number(flac?["TRACKNUMBER"]) ?? position.track ?? 0, disc: AlbumPosition.number(flac?["DISCNUMBER"]) ?? position.disc, duration: flac?.duration ?? duration,
                                 artwork: artwork, lyrics: lyrics, year: year)
    }

    static func readPosition(_ url: URL, filename: String) async throws -> (track: Int?, disc: Int?) {
        let asset = AVURLAsset(url: url)
        var items = try await asset.load(.commonMetadata)
        for format in try await asset.load(.availableMetadataFormats) { items += try await asset.loadMetadata(for: format) }
        let native = await position(in: items, filename: filename)
        let flac = try? FLACMetadata.read(url)
        return (AlbumPosition.number(flac?["TRACKNUMBER"]) ?? native.track, AlbumPosition.number(flac?["DISCNUMBER"]) ?? native.disc)
    }

    static func readYear(_ url: URL) async throws -> Int? {
        if let native = try FLACMetadata.read(url)?.year, (1...9999).contains(native) { return native }
        let asset = AVURLAsset(url: url)
        var items = try await asset.load(.commonMetadata)
        for format in try await asset.load(.availableMetadataFormats) { items += try await asset.loadMetadata(for: format) }
        for item in items {
            let key = "\(item.commonKey?.rawValue ?? "") \(item.identifier?.rawValue ?? "")".lowercased()
            if key.contains("creationdate") || key.contains("tdrc") || key.contains("tyer") || key.contains("day"),
               let value = try? await item.load(.stringValue), let year = Int(value.prefix(4)), (1...9999).contains(year) { return year }
        }
        return nil
    }

    static func position(in items: [AVMetadataItem], filename: String) async -> (track: Int?, disc: Int?) {
        var track: Int?, disc: Int?
        for item in items {
            let key = "\(item.commonKey?.rawValue ?? "") \(item.identifier?.rawValue ?? "")".lowercased()
            let isTrack = key.contains("tracknumber") || key.contains("trck") || key.contains("trkn")
            let isDisc = key.contains("discnumber") || key.contains("partofaset") || key.contains("tpos") || key.contains("/disk")
            guard (isTrack && track == nil) || (isDisc && disc == nil) else { continue }
            var value = AlbumPosition.number(try? await item.load(.stringValue))
            if value == nil, let number = try? await item.load(.numberValue), (1...65535).contains(number.intValue) { value = number.intValue }
            if value == nil && (key.contains("trkn") || key.contains("/disk")) {
                value = AlbumPosition.mp4Number(try? await item.load(.dataValue))
            }
            if isTrack { track = value }
            if isDisc { disc = value }
        }
        let fallback = AlbumPosition.filename(filename)
        return (track ?? fallback.track, disc ?? fallback.disc)
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
