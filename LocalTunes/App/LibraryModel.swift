import SwiftUI
import Combine
import OSLog

enum AppTab: Hashable { case home, browse, search, library, playlists }

@MainActor
final class LibraryModel: ObservableObject {
    let paths: LibraryPaths
    let db: LibraryDatabase
    let player: PlaybackService
    private let importer: ImportService
    private var importTask: Task<Void, Never>?
    @Published var revision = 0
    @Published var selectedTab: AppTab = .home
    @Published var searchFocusRequest = 0
    @Published var playlists: [Playlist] = []
    @Published var songCount = 0
    @Published var musicBytes: Int64 = 0
    @Published var availableBytes: Int64 = 0
    @Published var progress: ImportProgress?
    @Published var isImporting = false
    @Published var showImportReport = false
    @Published var importFiles = false
    @Published var importFolder = false
    @Published var errorMessage: String?
    @Published var home = HomePreferences()
    @Published var recentSearches: [String] = []
    @Published var yearScanProgress: String?
    private var yearScanTask: Task<Void, Never>?
    @Published var artistScanProgress: String?
    private var artistScanTask: Task<Void, Never>?

    init(paths: LibraryPaths, db: LibraryDatabase) {
        self.paths = paths; self.db = db
        player = PlaybackService(db: db, paths: paths)
        importer = ImportService(db: db, paths: paths)
    }

    func load() async {
        do {
            playlists = try await db.state("playlists", as: [Playlist].self) ?? []
            home = try await db.state("home.v1", as: HomePreferences.self) ?? HomePreferences()
            recentSearches = try await db.state("search.history", as: [String].self) ?? []
            await refresh()
            await player.restore()
            scanMissingArtistTags()
        } catch { errorMessage = error.localizedDescription }
    }

    func refresh() async {
        do {
            let stats = try await db.statistics()
            songCount = stats.count; musicBytes = stats.bytes
            availableBytes = try paths.documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            revision += 1
        } catch { errorMessage = error.localizedDescription }
    }

    func importURLs(_ urls: [URL]) {
        guard !isImporting else { return }
        isImporting = true; progress = ImportProgress()
        importTask = Task {
            await importer.run(urls) { [weak self] update in await self?.receiveProgress(update) }
            isImporting = false; showImportReport = true
            await refresh()
        }
    }

    func cancelImport() { importTask?.cancel() }
    func openSearch() { selectedTab = .search; searchFocusRequest += 1 }
    private func receiveProgress(_ update: ImportProgress) { progress = update }
    func scanInbox() { importURLs([paths.inbox]) }

    func favourite(_ song: Song) async {
        do {
            if let updated = try await db.toggleFavourite(song.id) { player.refreshSong(updated) }
            revision += 1
        } catch { errorMessage = error.localizedDescription }
    }

    func play(search: String = "", favourite: Bool = false, group: LibraryGroup? = nil, value: String? = nil,
              sort: LibrarySort = .title, startingAt id: String? = nil, shuffled: Bool = false,
              searchFilters: SearchFilters = SearchFilters(), smart: SmartCollection? = nil) async {
        do {
            var ids = try await db.allIDs(search: search, favourite: favourite, group: group, value: value, sort: sort, searchFilters: searchFilters, smart: smart)
            if shuffled { ids.shuffle() }
            await rememberSearch(search)
            await player.play(ids: ids, startingAt: id, shuffled: shuffled)
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ song: Song) async {
        guard !isImporting else { errorMessage = "Finish or cancel the import before deleting songs."; return }
        let original = paths.audioURL(for: song)
        let trash = paths.staging.appendingPathComponent("delete-" + song.id)
        let exists = FileManager.default.fileExists(atPath: original.path)
        do {
            await player.removeSong(song.id)
            if exists { try FileManager.default.moveItem(at: original, to: trash) }
            do { try await db.remove(song.id) }
            catch {
                if exists { try? FileManager.default.moveItem(at: trash, to: original) }
                throw error
            }
            if exists { try? FileManager.default.removeItem(at: trash) }
            if let artwork = song.artworkPath { removeArtwork(artwork) }
            for url in [paths.lyricURL(song.id), paths.artwork.appendingPathComponent(song.id + ".jpg"), paths.artwork.appendingPathComponent(song.id + ".thumb.jpg")] {
                try? FileManager.default.removeItem(at: url)
            }
            for index in playlists.indices { playlists[index].songIDs.removeAll { $0 == song.id } }
            try await db.setState("playlists", value: playlists)
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func playAlbum(_ name: String, startingAt id: String? = nil, shuffled: Bool = false) async {
        do {
            var ids = try await db.allIDs(group: .album, value: name, sort: .albumTrack)
            if shuffled { ids.shuffle() }
            await player.play(ids: ids, startingAt: id, shuffled: shuffled)
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshAlbumPositions(_ name: String) async throws -> [String] {
        let ids = try await db.allIDs(group: .album, value: name)
        var failures: [String] = []
        for id in ids {
            guard let indexed = try await db.song(id) else { continue }
            do {
                let position = try await MetadataExtractor.readPosition(paths.audioURL(for: indexed), filename: indexed.originalFilename)
                // Read the newest row after suspension, preserving favourite/history changes.
                guard var current = try await db.song(id) else { continue }
                if let track = position.track { current.trackNumber = track }
                if let disc = position.disc { current.discNumber = disc }
                try await db.save(current)
                player.refreshSong(current)
            } catch { failures.append("\(indexed.title): \(error.localizedDescription)") }
        }
        revision += 1
        return failures
    }

    func savePlaylists(_ values: [Playlist]) async {
        do { try await db.setState("playlists", value: values); playlists = values; revision += 1 }
        catch { errorMessage = error.localizedDescription }
    }

    func createPlaylist(_ name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        await savePlaylists(playlists + [Playlist(name: name)])
    }

    func add(_ songID: String, to playlistID: String) async {
        var values = playlists
        guard let index = values.firstIndex(where: { $0.id == playlistID }) else { return }
        if !values[index].songIDs.contains(songID) { values[index].songIDs.append(songID) }
        await savePlaylists(values)
    }

    func rememberSearch(_ query: String) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        recentSearches.removeAll { $0.localizedCaseInsensitiveCompare(query) == .orderedSame }
        recentSearches.insert(query, at: 0); recentSearches = Array(recentSearches.prefix(12))
        do { try await db.setState("search.history", value: recentSearches) } catch { errorMessage = error.localizedDescription }
    }

    func clearSearches() async {
        do { try await db.setState("search.history", value: [String]()); recentSearches = [] }
        catch { errorMessage = error.localizedDescription }
    }

    func saveHome(_ preferences: HomePreferences) async {
        do { try await db.setState("home.v1", value: preferences); home = preferences }
        catch { errorMessage = error.localizedDescription }
    }

    func togglePin(_ pin: HomePin) async {
        var preferences = home
        if preferences.pins.contains(pin) { preferences.pins.removeAll { $0 == pin } }
        else { preferences.pins.append(pin); preferences.hidden.remove(.pinned) }
        if !preferences.pins.isEmpty && !preferences.order.contains(.pinned) { preferences.order.append(.pinned) }
        await saveHome(preferences)
    }

    func updateSong(_ id: String, edits: SongEdits, artwork: Data?) async throws {
        var edits = edits
        let old = try await db.song(id)?.artworkPath
        var created: String?
        if let artwork {
            created = try MetadataExtractor.writeArtwork(artwork, id: UUID().uuidString, paths: paths)
            guard let created else { throw LibraryError.message("Choose a supported image.") }
            edits.artworkPath = created
        }
        do {
            let updated = try await db.editSong(id, edits: edits)
            player.refreshSong(updated); revision += 1
        } catch {
            if let created { removeArtwork(created) }
            throw error
        }
        if let old, old != edits.artworkPath { removeArtwork(old) }
    }

    func applyAlbumArtwork(_ album: String, data: Data) async throws {
        let songs = try await db.songs(group: .album, value: album, limit: -1)
        var covers: [String: String] = [:]
        do {
            for song in songs {
                guard let path = try MetadataExtractor.writeArtwork(data, id: UUID().uuidString, paths: paths) else { throw LibraryError.message("Choose a supported image") }
                covers[song.id] = path
                await Task.yield()
            }
            let updated = try await db.setAlbumArtwork(album, paths: covers)
            for song in updated { player.refreshSong(song) }
            for song in songs { if let path = song.artworkPath { removeArtwork(path) } }
            revision += 1
        } catch {
            for path in covers.values { removeArtwork(path) }
            throw error
        }
    }

    private func removeArtwork(_ path: String) {
        for relative in [path, path.replacingOccurrences(of: ".jpg", with: ".thumb.jpg")] {
            try? FileManager.default.removeItem(at: paths.documents.appendingPathComponent(relative))
        }
    }

    func scanMissingYears() {
        guard yearScanTask == nil else { return }
        yearScanProgress = "Starting"
        yearScanTask = Task {
            defer { yearScanProgress = nil; yearScanTask = nil; revision += 1 }
            do {
                let ids = try await db.allIDs()
                var failures = 0
                for (index, id) in ids.enumerated() {
                    try Task.checkCancellation()
                    yearScanProgress = "\(index + 1) / \(ids.count)"
                    guard let song = try await db.song(id), song.year == nil else { continue }
                    do {
                        if let year = try await MetadataExtractor.readYear(paths.audioURL(for: song)),
                           let updated = try await db.fillMissingYear(id, year: year) { player.refreshSong(updated) }
                    } catch is CancellationError { throw CancellationError() }
                    catch { failures += 1 }
                }
                if failures > 0 { errorMessage = "Could not read release years from \(failures) files." }
            } catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func cancelYearScan() { yearScanTask?.cancel() }

    func scanMissingArtistTags() {
        guard artistScanTask == nil else { return }
        artistScanProgress = "Starting"
        artistScanTask = Task {
            defer { artistScanProgress = nil; artistScanTask = nil; revision += 1 }
            do {
                let ids = try await db.allIDs()
                for (index, id) in ids.enumerated() {
                    try Task.checkCancellation()
                    guard let song = try await db.song(id), song.artistTagsVersion == nil else { continue }
                    artistScanProgress = "\(index + 1) / \(ids.count)"
                    do {
                        let tags: FLACMetadata.Tags?
                        if song.originalFilename.lowercased().hasSuffix(".flac") {
                            tags = try await MetadataExtractor.readFLACArtistTags(paths.audioURL(for: song))
                        } else { tags = nil }
                        if let updated = try await db.fillMissingArtistTags(song, tags: tags) { player.refreshSong(updated) }
                        if index % 50 == 0 { revision += 1 }
                    } catch is CancellationError { throw CancellationError() }
                    catch { continue } // Keep existing credits if a managed file is unavailable.
                }
            } catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func cancelArtistScan() { artistScanTask?.cancel() }
}
