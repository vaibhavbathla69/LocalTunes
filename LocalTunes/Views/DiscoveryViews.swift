import SwiftUI
import UniformTypeIdentifiers

struct ArtistDetailView: View {
    @EnvironmentObject private var library: LibraryModel
    let name: String
    @State private var albums: [GroupSummary] = []
    @State private var songs: [Song] = []
    @State private var representative: Song?
    @State private var displayName = ""
    @State private var merging = false
    var body: some View {
        List {
            CollectionHeader(title: displayName.isEmpty ? name : displayName, subtitle: "\(albums.count) \(albums.count == 1 ? "album" : "albums")", song: representative, symbol: "person.fill")
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
            Section("Albums") {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(albums) { album in GroupCard(group: album, kind: .album).frame(width: 145) }
                    }.padding(.vertical, 8)
                }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            Section("Top songs") {
                ForEach(songs.prefix(10)) { song in
                    SongRow(song: song) { Task { await library.play(group: .artist, value: name, sort: .mostPlayed, startingAt: song.id) } }
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                NavigationLink("All songs") { SongListView(title: name, group: .artist, groupValue: name) }.listRowBackground(Color.clear)
            }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle(displayName.isEmpty ? name : displayName).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { merging = true } label: { Image(systemName: "person.2.fill").frame(width: 44, height: 44) }.accessibilityLabel("Merge duplicate artist").accessibilityIdentifier("artist.merge") } }
            .sheet(isPresented: $merging) { ArtistMergeView(target: displayName.isEmpty ? name : displayName) }
            .accessibilityIdentifier("artist.screen")
            .task(id: library.revision) {
                do {
                    displayName = try await library.db.artistDisplayName(name)
                    albums = try await library.db.groups(.album, searchFilters: SearchFilters(artist: name))
                    songs = try await library.db.songs(sort: .mostPlayed, group: .artist, value: name, limit: 10)
                    representative = songs.first
                } catch { library.errorMessage = error.localizedDescription }
            }
    }
}

struct SearchFilterEditor: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @Binding var filters: SearchFilters
    @State private var draft: SearchFilters
    @State private var year: String
    @State private var artists: [GroupSummary] = []
    @State private var albums: [GroupSummary] = []
    @State private var genres: [GroupSummary] = []
    init(filters: Binding<SearchFilters>) {
        _filters = filters; _draft = State(initialValue: filters.wrappedValue)
        _year = State(initialValue: filters.wrappedValue.year.map(String.init) ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                picker("Artist", selection: $draft.artist, groups: artists)
                picker("Album", selection: $draft.album, groups: albums)
                picker("Genre", selection: $draft.genre, groups: genres)
                LabeledContent("Year") { TextField("Any", text: $year).multilineTextAlignment(.trailing).keyboardType(.numberPad).accessibilityLabel("Year").accessibilityIdentifier("search.filter.year") }
                Button("Reset filters") { draft = SearchFilters(); year = "" }
            }.navigationTitle("Filters").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) { Button("Apply") {
                        draft.year = Int(year); filters = draft; dismiss()
                    }.disabled(!year.isEmpty && !(1...9999).contains(Int(year) ?? 0)).accessibilityIdentifier("search.filter.apply") }
                }
                .task {
                    do {
                        artists = try await library.db.groups(.artist)
                        albums = try await library.db.groups(.album)
                        genres = try await library.db.groups(.genre)
                    } catch { library.errorMessage = error.localizedDescription }
                }
        }
    }
    private func picker(_ label: String, selection: Binding<String>, groups: [GroupSummary]) -> some View {
        Picker(label, selection: selection) {
            Text("Any").tag("")
            ForEach(groups) { Text($0.name).tag($0.name) }
        }
    }
}

struct HomeEditorView: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: HomePreferences
    init(preferences: HomePreferences) { _draft = State(initialValue: preferences) }
    var body: some View {
        NavigationStack {
            List {
                Section("Sections") {
                    ForEach(draft.order) { section in
                        Toggle(section.title, isOn: Binding(get: { !draft.hidden.contains(section) }, set: { enabled in
                            if enabled { draft.hidden.remove(section) } else { draft.hidden.insert(section) }
                        })).accessibilityIdentifier("home.section.\(section.rawValue)")
                    }.onMove { from, to in draft.order.move(fromOffsets: from, toOffset: to) }
                }
                if !draft.pins.isEmpty {
                    Section("Pinned") {
                        ForEach(draft.pins) { pin in
                            Text(pin.kind == .album ? pin.value : (library.playlists.first { $0.id == pin.value }?.name ?? "Playlist"))
                        }.onDelete { draft.pins.remove(atOffsets: $0) }
                            .onMove { from, to in draft.pins.move(fromOffsets: from, toOffset: to) }
                    }
                }
                Button("Reset Home") { draft = HomePreferences() }
            }.environment(\.editMode, .constant(.active))
                .navigationTitle("Customize Home").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) { Button("Save") { Task { await library.saveHome(draft); dismiss() } }.accessibilityIdentifier("home.customize.save") }
                }
        }
    }
}

struct PinnedHomeView: View {
    @EnvironmentObject private var library: LibraryModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Pinned")
            ForEach(library.home.pins) { pin in
                if pin.kind == .album {
                    NavigationLink { AlbumDetailView(albumName: pin.value) } label: { Label(pin.value, systemImage: "square.stack.fill").font(.headline).padding(.vertical, 8) }
                        .contextMenu { Button("Unpin", systemImage: "pin.slash") { Task { await library.togglePin(pin) } } }
                } else if let playlist = library.playlists.first(where: { $0.id == pin.value }) {
                    NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: { Label(playlist.name, systemImage: "music.note.list").font(.headline).padding(.vertical, 8) }
                        .contextMenu { Button("Unpin", systemImage: "pin.slash") { Task { await library.togglePin(pin) } } }
                }
            }
        }
    }
}

struct ListeningStatsView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlaybackService
    @State private var report = ListeningReport()
    @State private var clearing = false
    var body: some View {
        List {
            Section {
                LabeledContent("Listening time", value: report.seconds.clock)
                LabeledContent("Plays", value: String(report.plays))
            }
            if !report.songs.isEmpty {
                Section("Top songs") {
                    ForEach(report.songs) { leader in
                        Button { Task { await library.play(startingAt: leader.id) } } label: { leaderRow(leader) }.buttonStyle(.plain)
                    }
                }
            }
            if !report.artists.isEmpty {
                Section("Top artists") {
                    ForEach(report.artists) { leader in NavigationLink { ArtistDetailView(name: leader.title) } label: { leaderRow(leader) } }
                }
            }
            Section { Button("Clear listening stats", role: .destructive) { clearing = true } }
        }.navigationTitle("Listening stats").accessibilityIdentifier("stats.screen")
            .task { await reload() }
            .confirmationDialog("Clear listening stats?", isPresented: $clearing, titleVisibility: .visible) {
                Button("Clear stats", role: .destructive) { Task {
                    do { try await player.clearListeningHistory(); await reload(); library.revision += 1 }
                    catch { library.errorMessage = error.localizedDescription }
                } }
            }
    }
    private func leaderRow(_ leader: ListeningLeader) -> some View {
        HStack {
            Text(leader.title).lineLimit(2)
            Spacer()
            VStack(alignment: .trailing) {
                Text(leader.seconds.clock).monospacedDigit()
                Text("\(leader.plays) plays").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func reload() async {
        await player.flushListening()
        do { report = try await library.db.listeningReport() } catch { library.errorMessage = error.localizedDescription }
    }
}

struct SongEditorView: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let song: Song
    @State private var draft: SongEdits
    @State private var track: String
    @State private var disc: String
    @State private var year: String
    @State private var choosingArtwork = false
    @State private var image: Data?
    @State private var saving = false
    @State private var error: String?
    init(song: Song) {
        self.song = song
        _draft = State(initialValue: SongEdits(title: song.title, artist: song.artist, album: song.album, genre: song.genre, track: song.trackNumber, disc: song.discNumber, year: song.year, artworkPath: song.artworkPath))
        _track = State(initialValue: song.trackNumber > 0 ? String(song.trackNumber) : "")
        _disc = State(initialValue: song.discNumber.map(String.init) ?? "")
        _year = State(initialValue: song.year.map(String.init) ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    field("Title", text: $draft.title)
                    field("Artist", text: $draft.artist)
                    field("Album", text: $draft.album)
                    field("Genre", text: $draft.genre)
                    field("Track", text: $track, numeric: true)
                    field("Disc", text: $disc, numeric: true)
                    field("Year", text: $year, numeric: true)
                }
                Section("Artwork") {
                    if let image, let preview = UIImage(data: image) { Image(uiImage: preview).resizable().scaledToFit().frame(height: 160) }
                    else if draft.artworkPath != nil { ArtworkView(song: song, size: 160, fullSize: true) }
                    Button("Choose image", systemImage: "photo") { choosingArtwork = true }
                    Button("Remove artwork", role: .destructive) { image = nil; draft.artworkPath = nil }
                }
                Section {
                    Button("Read details from file", systemImage: "arrow.clockwise") { Task { await readTags() } }.disabled(saving)
                } footer: { Text("Edits are saved in LocalTunes. The audio file stays unchanged.") }
            }.disabled(saving).navigationTitle("Edit details").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .topBarTrailing) { Button("Save") { Task { await save() } }.disabled(saving).accessibilityIdentifier("song.edit.save") }
                }
                .fileImporter(isPresented: $choosingArtwork, allowedContentTypes: [.image]) { result in
                    do {
                        let url = try result.get(); let granted = url.startAccessingSecurityScopedResource()
                        defer { if granted { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 20 * 1024 * 1024 else { throw LibraryError.message("Choose an image under 20 MB.") }
                        let data = try Data(contentsOf: url)
                        guard UIImage(data: data) != nil else { throw LibraryError.message("Unsupported image.") }
                        image = data
                    } catch { self.error = error.localizedDescription }
                }
                .alert("Edit details", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }
    private func field(_ title: String, text: Binding<String>, numeric: Bool = false) -> some View {
        LabeledContent(title) {
            TextField(title, text: text).multilineTextAlignment(.trailing).keyboardType(numeric ? .numberPad : .default)
                .accessibilityLabel(title).accessibilityIdentifier("song.edit.\(title.lowercased())")
        }
    }
    private func readTags() async {
        saving = true; defer { saving = false }
        do {
            let metadata = try await MetadataExtractor.extract(library.paths.audioURL(for: song), originalName: song.originalFilename)
            draft.title = metadata.title; draft.artist = metadata.artist; draft.album = metadata.album; draft.genre = metadata.genre
            track = metadata.track > 0 ? String(metadata.track) : ""; disc = metadata.disc.map(String.init) ?? ""; year = metadata.year.map(String.init) ?? ""
            if let artwork = metadata.artwork { image = artwork }
        } catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard track.isEmpty || (1...65535).contains(Int(track) ?? 0), disc.isEmpty || (1...65535).contains(Int(disc) ?? 0), year.isEmpty || (1...9999).contains(Int(year) ?? 0) else { error = "Check the track, disc and year."; return }
        draft.track = Int(track) ?? 0; draft.disc = Int(disc); draft.year = Int(year)
        saving = true; defer { saving = false }
        do { try await library.updateSong(song.id, edits: draft, artwork: image); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
