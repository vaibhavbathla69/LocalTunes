import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var recent: [Song] = []
    @State private var added: [Song] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("ON YOUR FREQUENCY").font(.caption.weight(.bold)).tracking(3).foregroundStyle(Palette.accent)
                    Text("A little closer\nto your music.").font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("\(library.songCount) songs. All yours. Always here.").font(.subheadline).foregroundStyle(.secondary)
                    if library.songCount == 0 {
                        Button { library.importFiles = true } label: { Label("Bring your music", systemImage: "plus").font(.headline).padding(.vertical, 8) }
                            .buttonStyle(.borderedProminent).foregroundStyle(Palette.background).tint(Palette.accent)
                    } else {
                        Button { Task { await library.play(shuffled: true) } } label: { Label("Shuffle your library", systemImage: "shuffle").font(.headline).padding(.vertical, 6) }
                            .buttonStyle(.borderedProminent).foregroundStyle(Palette.background).tint(Palette.accent)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [Color(red: 0.16, green: 0.24, blue: 0.19), Palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
                HStack(spacing: 12) {
                    NavigationLink { SongListView(title: "Favourites", favourite: true) } label: {
                        Label("Favourites", systemImage: "heart.fill").font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 20).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                    }
                    NavigationLink { PlaylistsView() } label: {
                        Label("Playlists", systemImage: "music.note.list").font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 20).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                    }
                }.buttonStyle(.plain)
                if !recent.isEmpty {
                    VStack(spacing: 14) {
                        SectionHeading(title: "Back in rotation", subtitle: "Your recently played")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 16) {
                                ForEach(recent) { song in
                                    Button { Task { await library.play(sort: .played, startingAt: song.id) } } label: {
                                        VStack(alignment: .leading, spacing: 9) {
                                            ArtworkView(song: song, size: 146, fullSize: true)
                                            Text(song.title).font(.subheadline.bold()).lineLimit(1)
                                            Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }.frame(width: 146, alignment: .leading)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                VStack(spacing: 14) {
                    HStack { SectionHeading(title: "Freshly added"); NavigationLink("See all") { SongListView(title: "Recently added", sort: .added) }.font(.subheadline) }
                    if added.isEmpty { Text("Import audio files or a folder from Files. Your library stays on this iPhone.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    ForEach(added) { song in SongRow(song: song) { Task { await library.play(sort: .added, startingAt: song.id) } } }
                }
            }.padding(20)
        }
        .background(Palette.background).navigationTitle("Listen").toolbar { ImportMenu() }
        .task(id: library.revision) {
            do {
                recent = try await library.db.songs(sort: .played, limit: 12).filter { $0.lastPlayedAt != nil }
                added = try await library.db.songs(sort: .added, limit: 8)
            } catch { library.errorMessage = error.localizedDescription }
        }
    }
}

struct LibraryView: View {
    @State private var selection = "Songs"
    private let sections = ["Songs", "Albums", "Artists", "Genres"]
    var body: some View {
        VStack(spacing: 0) {
            Picker("Browse library", selection: $selection) { ForEach(sections, id: \.self) { Text($0) } }.pickerStyle(.segmented).padding()
            switch selection {
            case "Albums": GroupListView(kind: .album)
            case "Artists": GroupListView(kind: .artist)
            case "Genres": GroupListView(kind: .genre)
            default: SongListView(title: "Library", embedded: true)
            }
        }.background(Palette.background).navigationTitle("Library").toolbar { ImportMenu() }
    }
}

struct SongListView: View {
    @EnvironmentObject private var library: LibraryModel
    var title: String
    var search = ""
    var favourite = false
    var group: LibraryGroup? = nil
    var groupValue: String? = nil
    var sort: LibrarySort = .title
    var embedded = false
    @State private var songs: [Song] = []
    @State private var canLoadMore = true
    @State private var loading = false
    @State private var queryGeneration = 0
    private var queryKey: String { "\(search)|\(favourite)|\(group?.rawValue ?? "")|\(groupValue ?? "")|\(sort.rawValue)|\(library.revision)" }

    var body: some View {
        List {
            if !songs.isEmpty {
                HStack {
                    Button { play(nil) } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                    Button { Task { await library.play(search: search, favourite: favourite, group: group, value: groupValue, sort: sort, shuffled: true) } } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                }.listRowBackground(Color.clear)
            }
            ForEach(songs) { song in SongRow(song: song) { play(song.id) }.listRowBackground(Color.clear) }
            if canLoadMore {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear).task { await loadNext() }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(Palette.background)
        .overlay {
            if songs.isEmpty && !loading && !canLoadMore {
                ContentUnavailableView(search.isEmpty ? "Make room for music" : "No matches", systemImage: search.isEmpty ? "music.note" : "magnifyingglass", description: Text(search.isEmpty ? "Import songs using the + button. Favourites appear here after you add them." : "Try a song, album or artist name."))
            }
        }
        .navigationTitle(embedded ? "Library" : title)
        .task(id: queryKey) {
            queryGeneration += 1
            songs = []; canLoadMore = true; loading = false
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            await loadNext()
        }
    }

    private func play(_ id: String?) { Task { await library.play(search: search, favourite: favourite, group: group, value: groupValue, sort: sort, startingAt: id) } }
    private func loadNext() async {
        guard !loading, canLoadMore else { return }
        loading = true
        let token = queryGeneration
        do {
            let batch = try await library.db.songs(search: search, sort: sort, favourite: favourite, group: group, value: groupValue, limit: 100, offset: songs.count)
            guard token == queryGeneration else { return }
            guard !Task.isCancelled else { loading = false; return }
            let known = Set(songs.map(\.id))
            songs.append(contentsOf: batch.filter { !known.contains($0.id) }); canLoadMore = batch.count == 100
        } catch { if token == queryGeneration { library.errorMessage = error.localizedDescription; canLoadMore = false } }
        if token == queryGeneration { loading = false }
    }
}

struct GroupListView: View {
    @EnvironmentObject private var library: LibraryModel
    let kind: LibraryGroup
    var search = ""
    @State private var groups: [GroupSummary] = []
    var body: some View {
        List(groups) { group in
            NavigationLink { SongListView(title: group.name, group: kind, groupValue: group.name) } label: {
                HStack(spacing: 14) {
                    Image(systemName: kind == .album ? "square.stack" : (kind == .artist ? "person.crop.circle" : "guitars"))
                        .font(.title2).foregroundStyle(Palette.accent).frame(width: 44, height: 52)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.name).font(.headline)
                        Text("\(group.count) songs").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }.listRowBackground(Color.clear)
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Palette.background)
            .task(id: "\(kind.rawValue)|\(search)|\(library.revision)") {
                do { groups = try await library.db.groups(kind, search: search) }
                catch { library.errorMessage = error.localizedDescription }
            }
    }
}

struct SearchView: View {
    @State private var text = ""
    @State private var scope = "Songs"
    var body: some View {
        VStack(spacing: 0) {
            Picker("Search category", selection: $scope) { Text("Songs").tag("Songs"); Text("Albums").tag("Albums"); Text("Artists").tag("Artists") }.pickerStyle(.segmented).padding(.horizontal)
            if scope == "Songs" { SongListView(title: "Search", search: text, embedded: true) }
            else { GroupListView(kind: scope == "Albums" ? .album : .artist, search: text) }
        }.background(Palette.background).navigationTitle("Search").searchable(text: $text, prompt: "Songs, albums, artists")
    }
}
