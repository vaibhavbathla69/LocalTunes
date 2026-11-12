import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlaybackService
    @Environment(\.scenePhase) private var scenePhase
    @State private var nowPlaying = false
    var body: some View {
        TabView {
            NavigationStack { HomeView() }.tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack { LibraryView() }.tabItem { Label("Library", systemImage: "square.stack.fill") }
            NavigationStack { SearchView() }.tabItem { Label("Search", systemImage: "magnifyingglass") }
            NavigationStack { PlaylistsView() }.tabItem { Label("Playlists", systemImage: "music.note.list") }
            NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if library.isImporting, let progress = library.progress {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(progress.filename).font(.caption).lineLimit(1)
                            ProgressView(value: Double(progress.completed) + progress.fileFraction, total: Double(max(1, progress.total)))
                        }
                        Button("Cancel") { library.cancelImport() }.font(.caption)
                    }.padding(12).background(Palette.surface)
                }
                if let song = player.currentSong {
                    HStack(spacing: 12) {
                        Button { nowPlaying = true } label: {
                            HStack {
                                ArtworkView(song: song, size: 42)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Open Now Playing: \(song.title)")
                            .accessibilityIdentifier("miniPlayer")
                        Button { Task { await player.toggle() } } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }
                            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                        Button { Task { await player.next() } } label: { Image(systemName: "forward.end.fill").frame(width: 44, height: 44) }.accessibilityLabel("Next song")
                    }.padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .overlay(alignment: .topLeading) {
                            GeometryReader { proxy in
                                Rectangle().fill(Palette.accent).frame(width: proxy.size.width * min(1, player.duration > 0 ? player.position / player.duration : 0), height: 2)
                            }.frame(height: 2)
                        }
                }
            }
        }
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
