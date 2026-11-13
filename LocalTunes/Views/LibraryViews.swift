import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlaybackService
    @State private var recent: [Song] = []
    @State private var added: [Song] = []
    private var spotlight: Song? { player.currentSong ?? recent.first ?? added.first }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Button { library.openSearch() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").font(.title3.weight(.semibold))
                        Text("Search").font(.body.weight(.semibold))
                        Spacer(minLength: 0)
                    }.foregroundStyle(Palette.background).padding(17).background(.white, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).accessibilityLabel("Search your music").accessibilityIdentifier("home.search")
                quickLinks
                if let song = spotlight {
                    SpotlightCard(song: song) { Task { await library.play(sort: .added, startingAt: song.id) } }
                }
                if !recent.isEmpty { SongShelf(title: "Recently played", songs: recent, sort: .played) }
                if !added.isEmpty {
                    SongShelf(title: "Recently added", songs: added, sort: .added)
                    VStack(spacing: 12) {
                        HStack { SectionHeading(title: "Songs"); NavigationLink("See all") { SongListView(title: "All songs") }.font(.subheadline.weight(.semibold)).foregroundStyle(Palette.muted) }
                        ForEach(added.prefix(4)) { song in SongRow(song: song) { Task { await library.play(sort: .added, startingAt: song.id) } } }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeading(title: "Import music")
                        HStack(spacing: 12) {
                            importTile("Files", symbol: "music.note", seed: "violet") { library.importFiles = true }
                            importTile("Folder", symbol: "folder.fill", seed: "teal") { library.importFolder = true }
                        }
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
        }.background { ArtworkBackdrop(song: spotlight, strength: 0.32).ignoresSafeArea() }
            .navigationTitle("Home").navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ImportMenu()
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape").frame(width: 36, height: 36) }.accessibilityLabel("Open settings")
                }
            }
            .accessibilityIdentifier("home.screen")
            .task(id: library.revision) {
                do {
                    recent = try await library.db.songs(sort: .played, limit: 12).filter { $0.lastPlayedAt != nil }
                    added = try await library.db.songs(sort: .added, limit: 12)
                } catch { library.errorMessage = error.localizedDescription }
            }
    }

    private var quickLinks: some View {
        HStack(spacing: 10) {
            NavigationLink { SongListView(title: "Liked songs", favourite: true) } label: {
                quickLink("Liked songs", symbol: "heart.fill", colors: [.purple, .indigo])
            }
            Button { library.selectedTab = .playlists } label: { quickLink("Playlists", symbol: "music.note.list", colors: [.teal, .blue]) }
        }.buttonStyle(.plain)
    }
    private func quickLink(_ title: String, symbol: String, colors: [Color]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.body.bold()).frame(width: 44, height: 52).background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(title).font(.caption.weight(.bold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.trailing, 8).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9)).clipShape(RoundedRectangle(cornerRadius: 9))
    }
    private func importTile(_ title: String, symbol: String, seed: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol).font(.title2).padding(.bottom, 10)
                Text(title).font(.headline)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                .background { AlbumGradient(colors: .fallback(seed: seed), strength: 0.9) }.clipShape(RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }
}

private struct SpotlightCard: View {
    let song: Song
    let action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 20) {
                CollectionCover(song: song, symbol: "waveform", size: 126, seed: "LocalTunes spotlight").shadow(color: .black.opacity(0.3), radius: 15, y: 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text(song.title).font(.title2.weight(.heavy)).lineLimit(3).minimumScaleFactor(0.8)
                    Text(song.artist).font(.subheadline).foregroundStyle(.white.opacity(0.72)).lineLimit(3)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text(song.album).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                Spacer(minLength: 8)
                Button(action: action) { Image(systemName: "play.fill").font(.title3.bold()).foregroundStyle(Palette.background).frame(width: 52, height: 52).background(Palette.accent, in: Circle()) }
                    .accessibilityLabel("Play \(song.title)")
            }
        }.padding(22).background { ArtworkBackdrop(song: song, strength: 0.9) }
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}

private struct SongShelf: View {
    @EnvironmentObject private var library: LibraryModel
    let title: String
    let songs: [Song]
    let sort: LibrarySort
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(songs) { song in
                        Button { Task { await library.play(sort: sort, startingAt: song.id) } } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                ArtworkView(song: song, size: 156, fullSize: true).shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                                Text(song.title).font(.subheadline.bold()).lineLimit(1)
                                Text(song.artist).font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
                            }.frame(width: 156, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }.padding(.bottom, 8)
            }
        }
    }
}

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
    @State private var songs: [Song] = []
    @State private var canLoadMore = true
    @State private var loading = false
    @State private var queryGeneration = 0
    private var queryKey: String { "\(search)|\(favourite)|\(group?.rawValue ?? "")|\(groupValue ?? "")|\(sort.rawValue)|\(library.revision)" }
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
                    Button { Task { await library.play(search: search, favourite: favourite, group: group, value: groupValue, sort: sort, shuffled: true) } } label: { Image(systemName: "shuffle").font(.title3).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("Shuffle these songs")
                    Button { play(nil) } label: { Image(systemName: "play.fill").foregroundStyle(Palette.background).frame(width: 46, height: 46).background(Palette.accent, in: Circle()) }.buttonStyle(.plain).accessibilityLabel("Play these songs")
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
    @State private var groups: [GroupSummary] = []
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 18)], alignment: .leading, spacing: 24) {
                ForEach(groups) { group in GroupCard(group: group, kind: kind) }
            }.padding(20)
        }.background(Palette.background).scrollDismissesKeyboard(.interactively)
            .overlay { if groups.isEmpty { ContentUnavailableView(search.isEmpty ? "No music" : "No matches", systemImage: kind == .artist ? "person.crop.circle" : "square.stack") } }
            .task(id: "\(kind.rawValue)|\(search)|\(library.revision)") {
                do { groups = try await library.db.groups(kind, search: search) } catch { library.errorMessage = error.localizedDescription }
            }
    }
}

private struct GroupCard: View {
    @EnvironmentObject private var library: LibraryModel
    let group: GroupSummary
    let kind: LibraryGroup
    @State private var representative: Song?
    var body: some View {
        NavigationLink {
            if kind == .album { AlbumDetailView(albumName: group.name) }
            else { SongListView(title: group.name, group: kind, groupValue: group.name) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { proxy in
                    CollectionCover(song: representative, symbol: kind == .artist ? "person.fill" : "square.stack.fill", size: proxy.size.width, seed: group.name)
                        .clipShape(RoundedRectangle(cornerRadius: kind == .artist ? proxy.size.width / 2 : 12))
                }.aspectRatio(1, contentMode: .fit)
                Text(group.name).font(.subheadline.bold()).lineLimit(2)
                Text("\(group.count) \(group.count == 1 ? "song" : "songs")").font(.caption).foregroundStyle(Palette.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).accessibilityIdentifier("collection.\(kind.rawValue).\(group.name)")
            .task(id: group.id) {
                do { representative = try await library.db.songs(group: kind, value: group.name, limit: 1).first } catch { library.errorMessage = error.localizedDescription }
            }
    }
}

struct SearchView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var text = ""
    @State private var scope = "Songs"
    var body: some View {
        VStack(spacing: 16) {
            SearchField(text: $text, focusRequest: library.searchFocusRequest).padding(.horizontal, 20)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { SearchLandingView() }
            else {
                HStack(spacing: 8) {
                    ForEach(["Songs", "Albums", "Artists"], id: \.self) { value in FilterPill(title: value, selected: scope == value) { scope = value } }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 20)
                if scope == "Songs" { SongListView(title: "Search", search: text, embedded: true) }
                else { GroupListView(kind: scope == "Albums" ? .album : .artist, search: text) }
            }
        }.padding(.top, 8).background(Palette.background).navigationTitle("Search").navigationBarTitleDisplayMode(.large)
            .toolbar { ImportMenu() }
    }
}

private struct SearchLandingView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var recent: [Song] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    browseTile("Albums", symbol: "square.stack.fill", kind: .album, seed: "purple albums")
                    browseTile("Artists", symbol: "person.fill", kind: .artist, seed: "cyan artists")
                    browseTile("Genres", symbol: "guitars.fill", kind: .genre, seed: "red genres")
                    NavigationLink { SongListView(title: "Liked songs", favourite: true) } label: { browseLabel("Liked songs", symbol: "heart.fill", seed: "indigo favourites") }.buttonStyle(.plain)
                }
                if !recent.isEmpty {
                    SectionHeading(title: "Recently added")
                    ForEach(recent) { song in SongRow(song: song) { Task { await library.play(sort: .added, startingAt: song.id) } } }
                }
            }.padding(20)
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
            HStack { Spacer(); Image(systemName: symbol).font(.system(size: 38, weight: .medium)).rotationEffect(.degrees(15)).foregroundStyle(.white.opacity(0.75)) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background { AlbumGradient(colors: .fallback(seed: seed), strength: 1) }.clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
