import SwiftUI

struct AlbumDetailView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlaybackService
    let albumName: String
    var accessibilityPrefix = "album"
    @State private var songs: [Song] = []
    @State private var summary: AlbumSummary?
    @State private var isLoading = false
    @State private var hasMore = false
    @State private var generation = 0
    @State private var reordering = false
    @State private var refreshing = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            CollectionHeader(title: albumName, subtitle: albumDescription, song: songs.first, symbol: "square.stack.fill")
                .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
            if let summary, summary.count > 0 {
                HStack {
                    Button { reordering = true } label: {
                        Label(summary.hasCustomOrder ? "Custom order" : "Disc & track order", systemImage: "list.number")
                            .font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                    }.buttonStyle(.plain).accessibilityLabel("Reorder album tracks").accessibilityIdentifier("\(accessibilityPrefix).reorder").disabled(refreshing)
                    Spacer()
                    Button { Task { await library.playAlbum(albumName, shuffled: true) } } label: {
                        Image(systemName: "shuffle").font(.title3).frame(width: 44, height: 46)
                    }.buttonStyle(.plain).accessibilityLabel("Shuffle album").accessibilityIdentifier("\(accessibilityPrefix).shuffle")
                    Button { Task { await library.playAlbum(albumName) } } label: {
                        Image(systemName: "play.fill").foregroundStyle(Palette.background).frame(width: 48, height: 48).background(Palette.accent, in: Circle())
                    }.buttonStyle(.plain).accessibilityLabel("Play album in order").accessibilityIdentifier("\(accessibilityPrefix).play")
                }.listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
            ForEach(songs) { song in
                SongRow(song: song, positionLabel: positionLabel(song), accessibilityID: "\(accessibilityPrefix).track.\(song.title)") {
                    Task { await library.playAlbum(albumName, startingAt: song.id) }
                }.listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
            if hasMore { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear).task { await loadMore() } }
            if !songs.isEmpty {
                Button { reordering = true } label: { Label("Reorder tracks", systemImage: "arrow.up.arrow.down").font(.subheadline.bold()).padding(.vertical, 8) }
                    .disabled(refreshing).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(Palette.background)
        .navigationTitle(albumName).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if refreshing { ProgressView().accessibilityLabel("Reading album track numbers") }
                else {
                    Menu {
                        Button("Reorder tracks", systemImage: "arrow.up.arrow.down") { reordering = true }
                        Button("Use disc & track numbers", systemImage: "list.number") { Task { await resetOrder() } }
                        Button("Refresh track numbers from files", systemImage: "arrow.clockwise") { Task { await refreshTags() } }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                        .accessibilityLabel("Album options").disabled(songs.isEmpty)
                }
            }
        }
        .overlay {
            if isLoading && songs.isEmpty { ProgressView("Opening album…") }
            else if summary?.count == 0 { ContentUnavailableView("No songs", systemImage: "square.stack") }
        }
        .task(id: library.revision) { await reload() }
        .sheet(isPresented: $reordering) { AlbumOrderEditor(albumName: albumName) }
        .alert("Album", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var albumDescription: String {
        guard let summary else { return "" }
        let duration = summary.duration < 60 ? "\(Int(summary.duration)) sec" : "\(Int(summary.duration / 60)) min"
        return "\(summary.artist)\n\(summary.count) \(summary.count == 1 ? "song" : "songs") • \(duration)"
    }
    private func positionLabel(_ song: Song) -> String {
        let track = song.effectiveTrackNumber > 0 ? String(song.effectiveTrackNumber) : "—"
        return (summary?.maxDisc ?? 1) > 1 ? "\(song.effectiveDiscNumber)-\(track)" : track
    }
    private func reload() async {
        generation += 1
        let token = generation
        songs = []; summary = nil; isLoading = true; hasMore = false
        do {
            let info = try await library.db.albumSummary(albumName)
            let page = try await library.db.songs(sort: .albumTrack, group: .album, value: albumName, limit: 100)
            guard token == generation, !Task.isCancelled else { return }
            summary = info; songs = page; hasMore = page.count < info.count
        } catch { if token == generation { errorMessage = error.localizedDescription } }
        if token == generation { isLoading = false }
    }
    private func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        let token = generation
        do {
            let page = try await library.db.songs(sort: .albumTrack, group: .album, value: albumName, limit: 100, offset: songs.count)
            guard token == generation, !Task.isCancelled else { return }
            songs += page; hasMore = !page.isEmpty && songs.count < (summary?.count ?? 0)
        } catch { if token == generation { errorMessage = error.localizedDescription; hasMore = false } }
        if token == generation { isLoading = false }
    }
    private func resetOrder() async {
        do { try await library.db.resetAlbumOrder(albumName); library.revision += 1 }
        catch { errorMessage = error.localizedDescription }
    }
    private func refreshTags() async {
        refreshing = true
        do {
            let failures = try await library.refreshAlbumPositions(albumName)
            if !failures.isEmpty { errorMessage = failures.prefix(5).joined(separator: "\n") }
        } catch { errorMessage = error.localizedDescription }
        refreshing = false
    }
}

private struct AlbumOrderEditor: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let albumName: String
    @State private var songs: [Song] = []
    @State private var loading = true
    @State private var saving = false
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(songs) { song in
                        HStack(spacing: 12) {
                            ArtworkView(song: song, size: 40)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(song.title).font(.subheadline.bold()).lineLimit(2)
                                Text(song.artist).font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
                            }
                        }.padding(.vertical, 4)
                    }.onMove { offsets, destination in songs.move(fromOffsets: offsets, toOffset: destination) }
                } header: { Text(albumName) }
            }.environment(\.editMode, .constant(.active))
                .navigationTitle("Track order").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.disabled(saving).accessibilityIdentifier("album.order.cancel") }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(saving ? "Saving…" : "Save") { Task { await save() } }.disabled(loading || saving || songs.isEmpty).accessibilityIdentifier("album.order.save")
                    }
                }
                .overlay { if loading { ProgressView("Loading tracks…") } }
                .task {
                    do { songs = try await library.db.songs(sort: .albumTrack, group: .album, value: albumName, limit: -1) }
                    catch { errorMessage = error.localizedDescription }
                    loading = false
                }
                .alert("Could not save album order", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                    Button("OK") { errorMessage = nil }
                } message: { Text(errorMessage ?? "") }
        }
    }
    private func save() async {
        saving = true
        do { try await library.db.setAlbumOrder(albumName, songIDs: songs.map(\.id)); library.revision += 1; dismiss() }
        catch { errorMessage = error.localizedDescription }
        saving = false
    }
}
