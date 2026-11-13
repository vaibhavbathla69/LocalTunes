import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlaybackService
    @Environment(\.scenePhase) private var scenePhase
    @State private var nowPlaying = false
    var body: some View {
        TabView(selection: $library.selectedTab) {
            NavigationStack { HomeView() }.safeAreaInset(edge: .bottom, spacing: 0) { PlayerDock(showNowPlaying: $nowPlaying) }
                .tabItem { Label("Home", systemImage: "house.fill") }.tag(AppTab.home)
            NavigationStack { BrowseView() }.safeAreaInset(edge: .bottom, spacing: 0) { PlayerDock(showNowPlaying: $nowPlaying) }
                .tabItem { Label("Browse", systemImage: "square.grid.2x2.fill") }.tag(AppTab.browse)
            NavigationStack { LibraryView() }.safeAreaInset(edge: .bottom, spacing: 0) { PlayerDock(showNowPlaying: $nowPlaying) }
                .tabItem { Label("Library", systemImage: "square.stack.fill") }.tag(AppTab.library)
            NavigationStack { PlaylistsView() }.safeAreaInset(edge: .bottom, spacing: 0) { PlayerDock(showNowPlaying: $nowPlaying) }
                .tabItem { Label("Playlists", systemImage: "music.note.list") }.tag(AppTab.playlists)
            NavigationStack { SearchView() }.safeAreaInset(edge: .bottom, spacing: 0) { PlayerDock(showNowPlaying: $nowPlaying) }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(AppTab.search)
        }
        .toolbarBackground(.regularMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .fullScreenCover(isPresented: $nowPlaying) { NowPlayingView() }
        .fileImporter(isPresented: $library.importFiles, allowedContentTypes: [.audio, UTType(filenameExtension: "lrc") ?? .plainText, .plainText], allowsMultipleSelection: true) { result in handleImport(result) }
        .fileImporter(isPresented: $library.importFolder, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in handleImport(result) }
        .sheet(isPresented: $library.showImportReport) { ImportReportView() }
        .alert("Library", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK") { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") }
        .alert("Playback", isPresented: Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } })) {
            Button("OK") { player.errorMessage = nil }
        } message: { Text(player.errorMessage ?? "") }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { player.savePosition() }
            else { Task { await library.refresh() } }
        }
    }
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls): library.importURLs(urls)
        case .failure(let error): library.errorMessage = error.localizedDescription
        }
    }
}

private struct PlayerDock: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlaybackService
    @Binding var showNowPlaying: Bool
    var body: some View {
        VStack(spacing: 8) {
            if library.isImporting, let progress = library.progress {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(progress.filename).font(.caption.weight(.medium)).lineLimit(1)
                        ProgressView(value: Double(progress.completed) + progress.fileFraction, total: Double(max(1, progress.total))).tint(Palette.accent)
                    }
                    Button { library.cancelImport() } label: { Image(systemName: "xmark").frame(width: 36, height: 36) }.accessibilityLabel("Cancel import")
                }.padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            if let song = player.currentSong {
                HStack(spacing: 6) {
                    Button { showNowPlaying = true } label: {
                        HStack(spacing: 12) {
                            ArtworkView(song: song, size: 44)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(song.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                                Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Open Now Playing: \(song.title)").accessibilityIdentifier("miniPlayer")
                    Button { Task { await player.toggle() } } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 44, height: 48) }.accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    Button { Task { await player.next() } } label: { Image(systemName: "forward.end.fill").frame(width: 40, height: 48) }.accessibilityLabel("Next song")
                }.padding(.horizontal, 9).padding(.vertical, 9).padding(.bottom, 2)
                    .background(.regularMaterial)
                    .overlay(alignment: .bottom) {
                        GeometryReader { proxy in
                            Capsule().fill(Color.primary.opacity(0.1))
                            Capsule().fill(Palette.accent).frame(width: proxy.size.width * min(1, max(0, player.duration > 0 ? player.position / player.duration : 0)))
                        }.frame(height: 2).padding(.horizontal, 10).padding(.bottom, 4)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07), lineWidth: 1))
            }
        }.padding(.horizontal, 12).padding(.bottom, player.currentSong != nil || library.isImporting ? 7 : 0)
    }
}

struct ImportReportView: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if let progress = library.progress {
                    Section(progress.cancelled ? "Import cancelled" : "Import complete") {
                        LabeledContent("Songs added", value: "\(progress.imported)")
                        LabeledContent("Exact duplicates skipped", value: "\(progress.duplicates)")
                        LabeledContent("Lyrics attached", value: "\(progress.attachedLyrics)")
                    }
                    if !progress.errors.isEmpty {
                        Section("Files needing attention") { ForEach(Array(progress.errors.enumerated()), id: \.offset) { _, message in Text(message).font(.subheadline).textSelection(.enabled) } }
                    }
                    Section { Text("Your source files are preserved. Import folders include matching LRC files. Individual file providers may limit sibling-file access.").font(.footnote).foregroundStyle(.secondary) }
                }
            }.navigationTitle("Import results").toolbar { Button("Done") { dismiss() } }
        }
    }
}
