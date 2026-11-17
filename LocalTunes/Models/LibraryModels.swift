import Foundation

struct Song: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var relativePath: String
    var originalFilename: String
    var fingerprint: String
    var title: String
    var artist: String
    var album: String
    var genre: String
    var trackNumber: Int
    var duration: Double
    var byteCount: Int64
    var artworkPath: String?
    var addedAt: Date
    var lastPlayedAt: Date?
    var isFavourite: Bool = false
    var discNumber: Int? = nil
    var year: Int? = nil
    var artistTagsVersion: Int? = nil
    var albumArtist: String? = nil

    var effectiveTrackNumber: Int { trackNumber > 0 ? min(65535, trackNumber) : (AlbumPosition.filename(originalFilename).track ?? 0) }
    var effectiveDiscNumber: Int { min(65535, max(1, discNumber ?? AlbumPosition.filename(originalFilename).disc ?? 1)) }

    static func text(_ value: String?, fallback: String) -> String {
        let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? fallback : clean
    }

    static func fallbackTitle(filename: String) -> String {
        text((filename as NSString).deletingPathExtension, fallback: "Untitled")
    }
}

struct Playlist: Identifiable, Codable, Sendable {
    var id = UUID().uuidString
    var name: String
    var songIDs: [String] = []
    var createdAt = Date()
}

enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off, all, one
    var symbol: String { self == .one ? "repeat.1" : "repeat" }
    var next: Self { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
}

struct QueueEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    var songID: String
}

struct PlaybackPosition: Codable, Sendable {
    var entryID: String?
    var seconds: Double
}

/// Queue identity is independent of song identity: the same song may occur twice.
struct PlaybackQueue: Codable, Equatable, Sendable {
    var entries: [QueueEntry] = []
    var originalOrder: [String] = []
    var currentID: String?
    var shuffle = false
    var repeatMode: RepeatMode = .off
    var position: Double = 0
    // Optional so queues saved by earlier app versions still decode.
    private(set) var playNextEntryIDs: [String]?
    var currentIndex: Int? { entries.firstIndex { $0.id == currentID } }
    var current: QueueEntry? { currentIndex.map { entries[$0] } }

    mutating func replace(_ songIDs: [String], startAt index: Int) {
        entries = songIDs.map { QueueEntry(songID: $0) }
        originalOrder = entries.map(\.id)
        currentID = entries.indices.contains(index) ? entries[index].id : entries.first?.id
        position = 0
        playNextEntryIDs = nil
        if shuffle { randomizeUpcoming() }
    }

    func following(automatic: Bool) -> QueueEntry? {
        guard let index = currentIndex else { return entries.first }
        if automatic && repeatMode == .one { return entries[index] }
        if index + 1 < entries.count { return entries[index + 1] }
        return repeatMode == .all ? entries.first : nil
    }

    @discardableResult
    mutating func append(_ songID: String, next: Bool) -> String {
        let entry = QueueEntry(songID: songID)
        if next, let index = currentIndex {
            let upcoming = Set(entries.dropFirst(index + 1).map(\.id))
            let pending = Set((playNextEntryIDs ?? []).filter { upcoming.contains($0) })
            let insertion = (entries.lastIndex { pending.contains($0.id) } ?? index) + 1
            let predecessor = entries[insertion - 1].id
            entries.insert(entry, at: insertion)
            playNextEntryIDs = entries.filter { pending.contains($0.id) }.map(\.id) + [entry.id]
            let originalInsertion = originalOrder.firstIndex(of: predecessor).map { $0 + 1 } ?? originalOrder.count
            originalOrder.insert(entry.id, at: originalInsertion)
        } else {
            entries.append(entry)
            originalOrder.append(entry.id)
        }
        if currentID == nil { currentID = entry.id }
        return entry.id
    }

    mutating func toggleShuffle() {
        shuffle.toggle()
        if shuffle { randomizeUpcoming() }
        else {
            let ranks = Dictionary(uniqueKeysWithValues: originalOrder.enumerated().map { ($0.element, $0.offset) })
            entries.sort { ranks[$0.id, default: Int.max] < ranks[$1.id, default: Int.max] }
            keepPlayNextAhead()
        }
    }

    private mutating func randomizeUpcoming() {
        guard let index = currentIndex else { entries.shuffle(); return }
        let prefix = Array(entries[...index])
        let pending = Set(playNextEntryIDs ?? [])
        let upcoming = entries.dropFirst(index + 1)
        entries = prefix + upcoming.filter { pending.contains($0.id) } + upcoming.filter { !pending.contains($0.id) }.shuffled()
    }

    private mutating func keepPlayNextAhead() {
        guard let index = currentIndex else { return }
        let pending = Set(playNextEntryIDs ?? [])
        // Only pending entries still ahead of playback belong to the next batch.
        let upcoming = entries.dropFirst(index + 1)
        entries = Array(entries[...index]) + upcoming.filter { pending.contains($0.id) } + upcoming.filter { !pending.contains($0.id) }
    }

    mutating func remove(entryIDs: Set<String>) {
        let successor = following(automatic: false)?.id
        entries.removeAll { entryIDs.contains($0.id) }
        originalOrder.removeAll { entryIDs.contains($0) }
        playNextEntryIDs?.removeAll { entryIDs.contains($0) }
        if let id = currentID, entryIDs.contains(id) {
            currentID = entries.first(where: { $0.id == successor })?.id ?? entries.first?.id
            position = 0
        }
    }

    mutating func move(from: IndexSet, to: Int) {
        let selected = from.sorted().compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        let insertion = to - from.filter { $0 < to }.count
        for index in from.sorted(by: >) where entries.indices.contains(index) { entries.remove(at: index) }
        entries.insert(contentsOf: selected, at: min(max(0, insertion), entries.count))
        originalOrder = entries.map(\.id)
    }
}

enum LibrarySort: String, CaseIterable, Sendable { case title, added, played, albumTrack, mostPlayed }
enum LibraryGroup: String, CaseIterable, Sendable { case album, artist, genre }
struct GroupSummary: Identifiable, Sendable {
    var name: String
    var count: Int
    var key: String? = nil
    var value: String { key ?? name }
    var id: String { value }
}

struct AlbumSummary: Sendable {
    var count: Int
    var duration: Double
    var artist: String
    var hasCustomOrder: Bool
    var maxDisc: Int
}

struct AlbumDestination: Identifiable {
    var name: String
    var key: String? = nil
    var value: String { key ?? name }
    var id: String { value }
}

enum LibraryError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}
