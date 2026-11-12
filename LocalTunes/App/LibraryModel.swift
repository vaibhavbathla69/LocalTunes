import SwiftUI
import Combine
import OSLog

@MainActor
final class LibraryModel: ObservableObject {
    let paths: LibraryPaths
    let db: LibraryDatabase
    let player: PlaybackService
    private let importer: ImportService
    private var importTask: Task<Void, Never>?
    @Published var revision = 0
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

    init(paths: LibraryPaths, db: LibraryDatabase) {
        self.paths = paths; self.db = db
        player = PlaybackService(db: db, paths: paths)
        importer = ImportService(db: db, paths: paths)
    }

    func load() async {
        do {
            playlists = try await db.state("playlists", as: [Playlist].self) ?? []
            await refresh()
            await player.restore()
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
    private func receiveProgress(_ update: ImportProgress) { progress = update }
    func scanInbox() { importURLs([paths.inbox]) }

    func favourite(_ song: Song) async {
        do {
            if let updated = try await db.toggleFavourite(song.id) { player.refreshSong(updated) }
            revision += 1
        } catch { errorMessage = error.localizedDescription }
    }

    func play(search: String = "", favourite: Bool = false, group: LibraryGroup? = nil, value: String? = nil,
              sort: LibrarySort = .title, startingAt id: String? = nil, shuffled: Bool = false) async {
        do {
            var ids = try await db.allIDs(search: search, favourite: favourite, group: group, value: value, sort: sort)
            if shuffled { ids.shuffle() }
            await player.play(ids: ids, startingAt: id)
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
            for url in [paths.lyricURL(song.id), paths.artwork.appendingPathComponent(song.id + ".jpg"), paths.artwork.appendingPathComponent(song.id + ".thumb.jpg")] {
                try? FileManager.default.removeItem(at: url)
            }
            for index in playlists.indices { playlists[index].songIDs.removeAll { $0 == song.id } }
            try await db.setState("playlists", value: playlists)
            await refresh()
        } catch { errorMessage = error.localizedDescription }
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
}
