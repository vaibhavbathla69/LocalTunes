import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var selection = "Songs"
    @State private var search = ""
    private let sections = ["Songs", "Albums", "Artists", "Genres"]
    var body: some View {
        VStack(spacing: 14) {
            SearchField(text: $search, prompt: "Search your library").padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { ForEach(sections, id: \.self) { section in FilterPill(title: section, selected: selection == section) { selection = section } } }.padding(.horizontal, 20)
            }
            switch selection {
            case "Albums": GroupListView(kind: .album, search: search)
            case "Artists": GroupListView(kind: .artist, search: search)
            case "Genres": GroupListView(kind: .genre, search: search)
            default: SongListView(title: "Library", search: search, embedded: true)
            }
        }.padding(.top, 8).background(Palette.background).navigationTitle("Library").navigationBarTitleDisplayMode(.large)
            .toolbar {
                ImportMenu()
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }.accessibilityLabel("Open settings")
            }
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
    var searchFilters = SearchFilters()
    var smart: SmartCollection? = nil
    @State private var songs: [Song] = []
    @State private var canLoadMore = true
    @State private var loading = false
    @State private var queryGeneration = 0
    private var queryKey: String { "\(search)|\(favourite)|\(group?.rawValue ?? "")|\(groupValue ?? "")|\(sort.rawValue)|\(searchFilters)|\(smart?.rawValue ?? "")|\(library.revision)" }
    var body: some View {
        List {
            if !embedded && search.isEmpty {
                CollectionHeader(title: title, subtitle: favourite ? "" : (songs.first?.artist ?? ""), song: songs.first, symbol: favourite ? "heart.fill" : "square.stack.fill")
                    .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
            if !songs.isEmpty {
                HStack {
                    Label("Songs", systemImage: "music.note.list").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.muted)
                    Spacer()
                    Button { Task { await library.play(search: search, favourite: favourite, group: group, value: groupValue, sort: sort, shuffled: true, searchFilters: searchFilters, smart: smart) } } label: { Image(systemName: "shuffle").font(.title3).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("Shuffle these songs")
                    Button { play(nil) } label: { Image(systemName: "play.fill").foregroundStyle(.white).frame(width: 46, height: 46).background(Palette.accent, in: Circle()) }.buttonStyle(.plain).accessibilityLabel("Play these songs")
                }.listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
            ForEach(songs) { song in SongRow(song: song) { play(song.id) }.listRowSeparator(.hidden).listRowBackground(Color.clear) }
            if canLoadMore { HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear).task { await loadNext() } }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Palette.background).scrollDismissesKeyboard(.interactively)
            .overlay {
                if songs.isEmpty && !loading && !canLoadMore {
                    ContentUnavailableView(search.isEmpty ? (favourite ? "No liked songs" : "No songs") : "No matches", systemImage: search.isEmpty ? (favourite ? "heart" : "music.note") : "magnifyingglass")
                }
            }
            .collectionNavigationTitle(title, embedded: embedded)
            .task(id: queryKey) {
                queryGeneration += 1; songs = []; canLoadMore = true; loading = false
                if !search.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
                guard !Task.isCancelled else { return }
                await loadNext()
            }
    }
    private func play(_ id: String?) { Task { await library.play(search: search, favourite: favourite, group: group, value: groupValue, sort: sort, startingAt: id, searchFilters: searchFilters, smart: smart) } }
    private func loadNext() async {
        guard !loading, canLoadMore else { return }
        loading = true
        let token = queryGeneration
        do {
            let batch = try await library.db.songs(search: search, sort: sort, favourite: favourite, group: group, value: groupValue, limit: 100, offset: songs.count, searchFilters: searchFilters, smart: smart)
            guard token == queryGeneration else { return }
            guard !Task.isCancelled else { loading = false; return }
            let known = Set(songs.map(\.id)); songs.append(contentsOf: batch.filter { !known.contains($0.id) }); canLoadMore = batch.count == 100
        } catch { if token == queryGeneration { library.errorMessage = error.localizedDescription; canLoadMore = false } }
        if token == queryGeneration { loading = false }
    }
}

struct CollectionHeader: View {
    var title: String
    var subtitle: String
    var song: Song?
    var symbol = "music.note.list"
    var body: some View {
        VStack(spacing: 18) {
            CollectionCover(song: song, symbol: symbol, size: 172, seed: title).shadow(color: .black.opacity(0.3), radius: 18, y: 10)
            VStack(spacing: 7) { Text(title).font(.title.bold()).multilineTextAlignment(.center); if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(Palette.muted).multilineTextAlignment(.center) } }
        }.frame(maxWidth: .infinity).padding(24).background { ArtworkBackdrop(song: song, strength: 0.6) }
    }
}

struct GroupListView: View {
    @EnvironmentObject private var library: LibraryModel
    let kind: LibraryGroup
    var search = ""
    var searchFilters = SearchFilters()
    @State private var groups: [GroupSummary] = []
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 18)], alignment: .leading, spacing: 24) {
                ForEach(groups) { group in GroupCard(group: group, kind: kind) }
            }.padding(20)
        }.background(Palette.background).scrollDismissesKeyboard(.interactively)
            .overlay { if groups.isEmpty { ContentUnavailableView(search.isEmpty ? "No music" : "No matches", systemImage: kind == .artist ? "person.crop.circle" : "square.stack") } }
            .task(id: "\(kind.rawValue)|\(search)|\(searchFilters)|\(library.revision)") {
                do { groups = try await library.db.groups(kind, search: search, searchFilters: searchFilters) } catch { library.errorMessage = error.localizedDescription }
            }
    }
}

struct GroupCard: View {
    @EnvironmentObject private var library: LibraryModel
    let group: GroupSummary
    let kind: LibraryGroup
    @State private var representative: Song?
    var body: some View {
        NavigationLink {
            if kind == .album { AlbumDetailView(albumName: group.value) }
            else if kind == .artist { ArtistDetailView(name: group.name) }
            else { SongListView(title: group.name, group: kind, groupValue: group.name) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { proxy in
                    CollectionCover(song: representative, symbol: kind == .artist ? "person.fill" : "square.stack.fill", size: proxy.size.width, seed: group.name)
                        .clipShape(RoundedRectangle(cornerRadius: kind == .artist ? proxy.size.width / 2 : 12))
                }.aspectRatio(1, contentMode: .fit)
                Text(group.name).font(.subheadline.bold()).lineLimit(2)
                if kind == .album, let song = representative {
                    Text(Song.text(song.albumArtist, fallback: ArtistCredits.names(artist: song.artist, title: song.title).first ?? song.artist)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let year = song.year { Text(String(year)).font(.caption2).foregroundStyle(.secondary) }
                }
                Text("\(group.count) \(group.count == 1 ? "song" : "songs")").font(.caption).foregroundStyle(Palette.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).accessibilityIdentifier("collection.\(kind.rawValue).\(group.name)")
            .task(id: "\(group.id)|\(library.revision)") {
                do { representative = try await library.db.songs(group: kind, value: group.value, limit: 1).first } catch { library.errorMessage = error.localizedDescription }
            }
    }
}

struct SearchView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var text = ""
    @State private var scope = "Songs"
    @State private var filters = SearchFilters()
    @State private var filtering = false
    @State private var suggestions: [String] = []
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                SearchField(text: $text, focusRequest: library.searchFocusRequest, onSearch: { Task { await library.rememberSearch(text) } })
                Button { filtering = true } label: { Image(systemName: filters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill").font(.title2).frame(width: 44, height: 44) }
                    .accessibilityLabel("Search filters").accessibilityIdentifier("search.filters")
            }.padding(.horizontal, 20)
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(suggestions, id: \.self) { suggestion in
                        Button("Try: " + suggestion) { text = suggestion }.buttonStyle(.bordered)
                    } }.padding(.horizontal, 20)
                }
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filters.isEmpty {
                List {
                    if !library.recentSearches.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text("Recent searches").font(.headline); Spacer(); Button("Clear") { Task { await library.clearSearches() } } }
                            ForEach(library.recentSearches, id: \.self) { query in
                                Button { text = query } label: { Label(query, systemImage: "clock").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8) }.buttonStyle(.plain)
                            }
                        }.padding(.vertical, 8).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                    SearchLandingView()
                }.listStyle(.plain).scrollContentBackground(.hidden).background(Palette.background)
            }
            else {
                HStack(spacing: 8) {
                    ForEach(["Songs", "Albums", "Artists"], id: \.self) { value in FilterPill(title: value, selected: scope == value) { scope = value } }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 20)
                if scope == "Songs" { SongListView(title: "Search", search: text, embedded: true, searchFilters: filters) }
                else { GroupListView(kind: scope == "Albums" ? .album : .artist, search: text, searchFilters: filters) }
            }
        }.padding(.top, 8).background(Palette.background).navigationTitle("Search").navigationBarTitleDisplayMode(.large)
            .toolbar { ImportMenu() }
            .task(id: "\(text)|\(filters)|\(library.revision)") {
                suggestions = []
                do {
                    try await Task.sleep(nanoseconds: 300_000_000)
                    guard !text.isEmpty else { return }
                    let matches = try await library.db.songs(search: text, limit: 1, searchFilters: filters)
                    guard !Task.isCancelled, matches.isEmpty else { return }
                    let proposed = try await library.db.searchSuggestions(text)
                    guard !Task.isCancelled else { return }
                    suggestions = proposed
                } catch { }
            }
            .sheet(isPresented: $filtering) { SearchFilterEditor(filters: $filters) }
            .onDisappear { Task { await library.rememberSearch(text) } }
    }
}

private struct SearchLandingView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var recent: [Song] = []
    var body: some View {
        Group {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    browseTile("Albums", symbol: "square.stack.fill", kind: .album, seed: "purple albums")
                    browseTile("Artists", symbol: "person.fill", kind: .artist, seed: "cyan artists")
                    browseTile("Genres", symbol: "guitars.fill", kind: .genre, seed: "red genres")
                    NavigationLink { SongListView(title: "Liked songs", favourite: true) } label: { browseLabel("Liked songs", symbol: "heart.fill", seed: "indigo favourites") }.buttonStyle(.plain)
                }.padding(.vertical, 8).listRowBackground(Color.clear).listRowSeparator(.hidden)
                if !recent.isEmpty {
                    Section {
                        ForEach(recent) { song in SongRow(song: song) { Task { await library.play(sort: .added, startingAt: song.id) } } }
                    } header: { Text("Recently added").font(.headline).textCase(nil) }
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
        }.scrollDismissesKeyboard(.interactively).task(id: library.revision) {
            do { recent = try await library.db.songs(sort: .added, limit: 5) } catch { library.errorMessage = error.localizedDescription }
        }
    }
    private func browseTile(_ title: String, symbol: String, kind: LibraryGroup, seed: String) -> some View {
        NavigationLink { GroupListView(kind: kind).navigationTitle(title).navigationBarTitleDisplayMode(.inline) } label: { browseLabel(title, symbol: symbol, seed: seed) }.buttonStyle(.plain)
    }
    private func browseLabel(_ title: String, symbol: String, seed: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title3.bold())
            HStack { Spacer(); Image(systemName: symbol).font(.system(size: 38, weight: .medium)).foregroundStyle(Palette.muted) }
        }.foregroundStyle(.primary).padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
