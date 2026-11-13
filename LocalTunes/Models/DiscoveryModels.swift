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
    case shortcuts, pinned, featured, recentlyPlayed, recentlyAdded, songs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shortcuts: return "Shortcuts"
        case .pinned: return "Pinned"
        case .featured: return "Featured song"
        case .recentlyPlayed: return "Recently played"
        case .recentlyAdded: return "Recently added"
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
    var order = HomeSection.allCases
    var hidden: Set<HomeSection> = []
    var pins: [HomePin] = []
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
