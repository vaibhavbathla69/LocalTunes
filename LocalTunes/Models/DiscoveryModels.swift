import Foundation

struct SearchFilters: Codable, Equatable, Sendable {
    var artist = ""
    var album = ""
    var genre = ""
    var year: Int? = nil
    var isEmpty: Bool { artist.isEmpty && album.isEmpty && genre.isEmpty && year == nil }
}

enum SmartCollection: String, CaseIterable, Identifiable, Sendable {
    case recentlyAdded, mostPlayed, forgottenFavourites
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recentlyAdded: return "Recently added"
        case .mostPlayed: return "Most played"
        case .forgottenFavourites: return "Forgotten favourites"
        }
    }
    var symbol: String {
        switch self {
        case .recentlyAdded: return "clock"
        case .mostPlayed: return "chart.bar.fill"
        case .forgottenFavourites: return "heart.circle"
        }
    }
    var sort: LibrarySort { self == .mostPlayed ? .mostPlayed : .added }
}

enum HomeSection: String, CaseIterable, Codable, Identifiable {
    case recentlyPlayedAlbums, mostPlayedAlbums, mostPlayedSongs, stats, recentlyAdded, pinned
    // Decode old saved layouts without showing the retired shortcuts or spotlight.
    case shortcuts, featured, recentlyPlayed, songs
    static let defaultOrder: [HomeSection] = [.recentlyPlayedAlbums, .mostPlayedAlbums, .mostPlayedSongs, .stats, .recentlyAdded]
    static var allCases: [HomeSection] { defaultOrder + [.pinned] }
    var supported: Bool { Self.allCases.contains(self) }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recentlyPlayedAlbums: return "Recently played albums"
        case .mostPlayedAlbums: return "Most played albums"
        case .mostPlayedSongs: return "Most played songs"
        case .stats: return "Stats"
        case .recentlyAdded: return "Recently added"
        case .pinned: return "Pinned"
        case .shortcuts: return "Shortcuts"
        case .featured: return "Featured song"
        case .recentlyPlayed: return "Recently played"
        case .songs: return "Songs"
        }
    }
}

struct HomePin: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case album, playlist }
    var kind: Kind
    var value: String
    var id: String { kind.rawValue + ":" + value }
}

struct HomePreferences: Codable, Equatable {
    var order = HomeSection.defaultOrder
    var hidden: Set<HomeSection> = []
    var pins: [HomePin] = []
    var layoutVersion = 2
    init() {}
    private enum CodingKeys: String, CodingKey { case order, hidden, pins, layoutVersion }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pins = try values.decodeIfPresent([HomePin].self, forKey: .pins) ?? []
        let version = try values.decodeIfPresent(Int.self, forKey: .layoutVersion) ?? 1
        if version >= 2 {
            let saved = try values.decodeIfPresent([HomeSection].self, forKey: .order) ?? HomeSection.defaultOrder
            var seen: Set<HomeSection> = []
            order = saved.filter { $0.supported && seen.insert($0).inserted }
            order += HomeSection.defaultOrder.filter { !seen.contains($0) }
            hidden = try values.decodeIfPresent(Set<HomeSection>.self, forKey: .hidden) ?? []
            hidden = hidden.filter { $0.supported }
        }
    }
}

struct AlbumActivity: Identifiable, Sendable {
    var name: String
    var count: Int
    var plays: Int
    var representative: Song?
    var key: String? = nil
    var value: String { key ?? name }
    var id: String { value }
}

struct HomeFeed: Sendable {
    var recentAlbums: [AlbumActivity] = []
    var popularAlbums: [AlbumActivity] = []
    var popularSongs: [Song] = []
    var added: [Song] = []
    var report = ListeningReport()
}

struct ListeningLeader: Identifiable, Sendable {
    var id: String
    var title: String
    var seconds: Double
    var plays: Int
}

struct ListeningReport: Sendable {
    var seconds: Double = 0
    var plays = 0
    var songs: [ListeningLeader] = []
    var artists: [ListeningLeader] = []
}

struct SongEdits: Sendable {
    var title: String
    var artist: String
    var album: String
    var genre: String
    var track: Int
    var disc: Int?
    var year: Int?
    var artworkPath: String?
}

struct SleepTimerState: Equatable {
    var deadline: Date?
    var entryID: String?
    var isActive: Bool { deadline != nil || entryID != nil }
    func expired(at date: Date, currentEntry: String?) -> Bool {
        if let deadline, date >= deadline { return true }
        if let entryID, currentEntry != entryID { return true }
        return false
    }
}

struct LoudnessMeasurement: Codable, Sendable {
    var rms: Double
    var peak: Double
    // Attenuation only: never amplify, avoiding clipping and sudden boosts.
    var gain: Float {
        guard rms.isFinite, peak.isFinite, rms > 0, peak > 0 else { return 1 }
        return Float(max(0.01, min(1, min(0.1 / rms, 0.95 / peak))))
    }
}
