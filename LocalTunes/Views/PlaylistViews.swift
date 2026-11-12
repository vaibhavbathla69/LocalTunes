import SwiftUI

struct PlaylistsView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var creating = false
    @State private var name = ""
    var body: some View {
        List {
            NavigationLink { SongListView(title: "Favourites", favourite: true) } label: { Label("Favourites", systemImage: "heart.fill").foregroundStyle(Palette.accent).padding(.vertical, 12) }.listRowBackground(Color.clear)
            ForEach(library.playlists) { playlist in
                NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "music.note.list").font(.title).foregroundStyle(Palette.accent).frame(width: 50, height: 60).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 5) { Text(playlist.name).font(.headline); Text("\(playlist.songIDs.count) songs").font(.subheadline).foregroundStyle(.secondary) }
                    }
                }.listRowBackground(Color.clear)
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
            if let playlist {
                HStack {
                    Button { Task { await player.play(ids: playlist.songIDs) } } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                    Button { Task { await player.play(ids: playlist.songIDs.shuffled()) } } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                }.listRowBackground(Color.clear)
            }
            ForEach(songs) { song in
                SongRow(song: song) { Task { await player.play(ids: playlist?.songIDs ?? [], startingAt: song.id) } }.listRowBackground(Color.clear)
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
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Palette.background).navigationTitle(playlist?.name ?? "Playlist")
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
