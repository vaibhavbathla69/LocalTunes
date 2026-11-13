import SwiftUI

struct PlaylistsView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var creating = false
    @State private var name = ""
    var body: some View {
        List {
            VStack(alignment: .leading, spacing: 6) {
                Text("A mix for every version of you.").font(.title2.bold())
                Text("\(library.playlists.count) playlists • all on your iPhone").font(.subheadline).foregroundStyle(Palette.muted)
            }.padding(.vertical, 12).listRowBackground(Color.clear).listRowSeparator(.hidden)
            NavigationLink { SongListView(title: "Liked songs", favourite: true) } label: {
                HStack(spacing: 16) {
                    CollectionCover(symbol: "heart.fill", size: 70, seed: "Liked songs")
                    VStack(alignment: .leading, spacing: 6) { Text("Liked songs").font(.headline); Text("Your favourites, together").font(.caption).foregroundStyle(Palette.muted) }
                }.padding(.vertical, 6)
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            ForEach(library.playlists) { playlist in
                NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: {
                    PlaylistLibraryRow(playlist: playlist)
                }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            }.onMove { from, to in
                var values = library.playlists; values.move(fromOffsets: from, toOffset: to)
                Task { await library.savePlaylists(values) }
            }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Palette.background).navigationTitle("Playlists")
            .toolbar { ToolbarItem(placement: .topBarLeading) { EditButton() }; ToolbarItem(placement: .topBarTrailing) { Button("Create playlist", systemImage: "plus") { name = ""; creating = true } } }
            .alert("New playlist", isPresented: $creating) { TextField("Playlist name", text: $name); Button("Create") { Task { await library.createPlaylist(name) } }; Button("Cancel", role: .cancel) { } }
    }
}

struct PlaylistDetailView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlaybackService
    @Environment(\.dismiss) private var dismiss
    let playlistID: String
    @State private var songs: [Song] = []
    @State private var renaming = false
    @State private var deleting = false
    @State private var adding = false
    @State private var name = ""
    private var playlist: Playlist? { library.playlists.first { $0.id == playlistID } }
    var body: some View {
        List {
            CollectionHeader(title: playlist?.name ?? "Playlist", subtitle: "\(playlist?.songIDs.count ?? 0) songs • Curated by you", song: songs.first)
                .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
            if let playlist {
                HStack {
                    Button { Task { await player.play(ids: playlist.songIDs) } } label: { Label("Play", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10) }.buttonStyle(.borderedProminent).tint(Palette.accent).foregroundStyle(Palette.background)
                    Button { Task { await player.play(ids: playlist.songIDs.shuffled()) } } label: { Label("Shuffle", systemImage: "shuffle").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10) }.buttonStyle(.bordered).tint(.white)
                }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            ForEach(songs) { song in
                SongRow(song: song) { Task { await player.play(ids: playlist?.songIDs ?? [], startingAt: song.id) } }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            }.onDelete { offsets in
                var values = library.playlists
                guard let index = values.firstIndex(where: { $0.id == playlistID }) else { return }
                let ids = Set(offsets.map { songs[$0].id })
                values[index].songIDs.removeAll { ids.contains($0) }
                Task { await library.savePlaylists(values) }
            }.onMove { offsets, destination in
                var values = library.playlists
                guard let index = values.firstIndex(where: { $0.id == playlistID }) else { return }
                var ordered = songs.map(\.id); ordered.move(fromOffsets: offsets, toOffset: destination)
                values[index].songIDs = ordered
                Task { await library.savePlaylists(values) }
            }
            Button("Add songs", systemImage: "plus") { adding = true }.listRowBackground(Color.clear)
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Palette.background).navigationTitle(playlist?.name ?? "Playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                EditButton()
                Menu {
                    Button("Rename", systemImage: "pencil") { name = playlist?.name ?? ""; renaming = true }
                    Button("Delete playlist", systemImage: "trash", role: .destructive) { deleting = true }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Playlist options")
            }
            .task(id: library.revision) {
                var result: [Song] = []
                for id in playlist?.songIDs ?? [] {
                    do { if let song = try await library.db.song(id) { result.append(song) } }
                    catch { library.errorMessage = error.localizedDescription }
                }
                songs = result
            }
            .alert("Rename playlist", isPresented: $renaming) {
                TextField("Name", text: $name)
                Button("Save") {
                    var values = library.playlists
                    if let index = values.firstIndex(where: { $0.id == playlistID }), !name.trimmingCharacters(in: .whitespaces).isEmpty { values[index].name = name }
                    Task { await library.savePlaylists(values) }
                }; Button("Cancel", role: .cancel) { }
            }
            .confirmationDialog("Delete this playlist? Your songs stay in the library.", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete playlist", role: .destructive) { Task { await library.savePlaylists(library.playlists.filter { $0.id != playlistID }); dismiss() } }
            }
            .sheet(isPresented: $adding) { PlaylistSongPicker(playlistID: playlistID) }
    }
}

private struct PlaylistLibraryRow: View {
    @EnvironmentObject private var library: LibraryModel
    let playlist: Playlist
    @State private var song: Song?
    var body: some View {
        HStack(spacing: 16) {
            CollectionCover(song: song, size: 70, seed: playlist.name)
            VStack(alignment: .leading, spacing: 6) {
                Text(playlist.name).font(.headline).lineLimit(2)
                Text("Playlist • \(playlist.songIDs.count) songs").font(.caption).foregroundStyle(Palette.muted)
            }
        }.padding(.vertical, 6).task(id: playlist.songIDs.first) {
            if let id = playlist.songIDs.first { do { song = try await library.db.song(id) } catch { library.errorMessage = error.localizedDescription } }
            else { song = nil }
        }
    }
}

struct PlaylistPicker: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let songID: String
    @State private var name = ""
    var body: some View {
        NavigationStack {
            List {
                Section("Create playlist") {
                    TextField("Name", text: $name)
                    Button("Create and add song") { Task {
                        let playlist = Playlist(name: name.trimmingCharacters(in: .whitespacesAndNewlines), songIDs: [songID])
                        guard !playlist.name.isEmpty else { return }
                        await library.savePlaylists(library.playlists + [playlist]); dismiss()
                    } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("Your playlists") {
                    ForEach(library.playlists) { playlist in
                        Button(playlist.name) { Task { await library.add(songID, to: playlist.id); dismiss() } }
                    }
                }
            }.navigationTitle("Add to playlist").toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct PlaylistSongPicker: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let playlistID: String
    @State private var search = ""
    @State private var songs: [Song] = []
    @State private var loading = false
    @State private var hasMore = true
    @State private var generation = 0
    var body: some View {
        NavigationStack {
            List {
                ForEach(songs) { song in
                    Button { Task { await library.add(song.id, to: playlistID) } } label: {
                        HStack {
                            ArtworkView(song: song, size: 42)
                            VStack(alignment: .leading) { Text(song.title); Text(song.artist).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if library.playlists.first(where: { $0.id == playlistID })?.songIDs.contains(song.id) == true { Image(systemName: "checkmark.circle.fill") }
                            else { Image(systemName: "plus.circle") }
                        }
                    }.buttonStyle(.plain)
                }
                if hasMore { ProgressView().task { await loadMore() } }
            }.navigationTitle("Add songs").searchable(text: $search).toolbar { Button("Done") { dismiss() } }
                .task(id: search) { generation += 1; songs = []; hasMore = true; loading = false; await loadMore() }
        }
    }
    private func loadMore() async {
        guard !loading, hasMore else { return }
        loading = true
        let token = generation
        do {
            let result = try await library.db.songs(search: search, limit: 100, offset: songs.count)
            guard token == generation else { return }
            songs += result; hasMore = result.count == 100
        } catch { library.errorMessage = error.localizedDescription; hasMore = false }
        if token == generation { loading = false }
    }
}
