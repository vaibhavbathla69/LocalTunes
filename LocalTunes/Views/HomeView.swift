import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlaybackService
    @Environment(\.scenePhase) private var phase
    @State private var feed = HomeFeed()
    @State private var customizing = false
    private var refreshKey: String { "\(library.revision)|\(player.queue.currentID ?? "")|\(phase)" }
    var body: some View {
        List {
            Button { library.openSearch() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.title3.weight(.semibold))
                    Text("Search").font(.body.weight(.semibold)); Spacer()
                }.foregroundStyle(Palette.muted).padding(17).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain).accessibilityLabel("Search your music").accessibilityIdentifier("home.search")
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            ForEach(library.home.order.filter { $0.supported && !library.home.hidden.contains($0) }) { section in
                homeSection(section)
            }
            if library.songCount == 0 {
                Section("Import music") {
                    Button("Choose files", systemImage: "doc.badge.plus") { library.importFiles = true }
                    Button("Choose a folder", systemImage: "folder.badge.plus") { library.importFolder = true }
                }.listRowBackground(Color.clear)
            }
        }.listStyle(.plain).scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("Listen Now").navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.regularMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { customizing = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 36, height: 36) }.accessibilityLabel("Customize Home").accessibilityIdentifier("home.customize")
                    ImportMenu()
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape").frame(width: 36, height: 36) }.accessibilityLabel("Open settings")
                }
            }
            .sheet(isPresented: $customizing) { HomeEditorView(preferences: library.home) }
            .accessibilityIdentifier("home.screen")
            .task(id: refreshKey) {
                guard phase == .active else { return }
                await reload()
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                    await reload()
                }
            }
    }
    @ViewBuilder private func homeSection(_ section: HomeSection) -> some View {
        switch section {
        case .recentlyPlayedAlbums:
            if !feed.recentAlbums.isEmpty {
                Section { HomeAlbumShelf(albums: feed.recentAlbums, popular: false).listRowInsets(EdgeInsets()) } header: { heading(section.title) }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
        case .mostPlayedAlbums:
            if !feed.popularAlbums.isEmpty {
                Section { HomeAlbumShelf(albums: feed.popularAlbums, popular: true).listRowInsets(EdgeInsets()) } header: { heading(section.title) }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
        case .mostPlayedSongs:
            if !feed.popularSongs.isEmpty {
                Section {
                    ForEach(feed.popularSongs) { song in
                        SongRow(song: song, accessibilityID: "home.popular.\(song.title)") {
                            Task { await library.play(sort: .mostPlayed, startingAt: song.id, smart: .mostPlayed) }
                        }
                    }
                } header: { heading(section.title) }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
        case .stats:
            Section {
                NavigationLink { ListeningStatsView() } label: {
                    HStack(spacing: 20) {
                        metric("Listening time", value: feed.report.seconds.clock)
                        metric("Plays", value: String(feed.report.plays))
                    }.padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                }.accessibilityIdentifier("home.stats")
            } header: { heading(section.title) }.listRowBackground(Color.clear).listRowSeparator(.hidden)
        case .recentlyAdded:
            if !feed.added.isEmpty {
                Section {
                    ForEach(feed.added) { song in
                        SongRow(song: song, accessibilityID: "home.added.\(song.title)") { Task { await library.play(sort: .added, startingAt: song.id) } }
                    }
                    NavigationLink("See all") { SongListView(title: "Recently added", sort: .added) }
                } header: { heading(section.title) }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
        case .pinned:
            if !library.home.pins.isEmpty { PinnedHomeView().listRowBackground(Color.clear).listRowSeparator(.hidden) }
        case .shortcuts, .featured, .recentlyPlayed, .songs: EmptyView()
        }
    }
    private func heading(_ title: String) -> some View {
        Text(title).font(.title2.bold()).foregroundStyle(Color(uiColor: .label)).textCase(nil).padding(.top, 16).padding(.bottom, 6)
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(Palette.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func reload() async {
        await player.flushListening()
        guard !Task.isCancelled else { return }
        do { feed = try await library.db.homeFeed() } catch { library.errorMessage = error.localizedDescription }
    }
}

private struct HomeAlbumShelf: View {
    let albums: [AlbumActivity]
    let popular: Bool
    @ScaledMetric(relativeTo: .body) private var coverSize: CGFloat = 176
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(albums) { album in
                    NavigationLink { AlbumDetailView(albumName: album.value) } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            CollectionCover(song: album.representative, size: coverSize, seed: album.name)
                            Text(album.name).font(.subheadline.bold()).lineLimit(2)
                            Text(popular ? "\(album.plays) \(album.plays == 1 ? "play" : "plays")" : "\(album.count) \(album.count == 1 ? "song" : "songs")")
                                .font(.caption).foregroundStyle(Palette.muted)
                        }.frame(width: coverSize, alignment: .leading)
                    }.buttonStyle(.plain).accessibilityIdentifier("home.\(popular ? "popular" : "recent").album.\(album.name)")
                }
            }
        }.contentMargins(.horizontal, 20, for: .scrollContent).scrollClipDisabled().frame(height: coverSize + 82)
    }
}
