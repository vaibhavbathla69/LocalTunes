import Foundation

enum AlbumIdentity {
    static let prefix = "ltalbum:"
    static func key(for song: Song) -> String {
        let primary = ArtistCredits.names(artist: song.artist, title: song.title).first ?? song.artist
        let artist = Song.text(song.albumArtist, fallback: primary)
        let values = [song.album, ArtistCredits.key(artist), song.year.map(String.init) ?? ""]
        let data = try! JSONSerialization.data(withJSONObject: values)
        return prefix + data.base64EncodedString()
    }
    static func title(_ value: String) -> String {
        guard value.hasPrefix(prefix), let data = Data(base64Encoded: String(value.dropFirst(prefix.count))),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String], let title = values.first else { return value }
        return title
    }
    static func column(_ value: String) -> String { value.hasPrefix(prefix) ? "album_group" : "album" }
}
