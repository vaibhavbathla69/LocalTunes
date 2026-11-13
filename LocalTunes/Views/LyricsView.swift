import SwiftUI
import UniformTypeIdentifiers

struct LyricsView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlaybackService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("lyricsAutoFollow") private var autoFollow = true
    @State private var following = true
    @State private var raw = ""
    @State private var parsed = LyricsParser.parse("")
    @State private var editing = false
    @State private var attaching = false
    @State private var error: String?
    private var active: Int? { parsed.activeIndex(at: player.position) }
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ArtworkBackdrop(song: player.currentSong, strength: 0.9).ignoresSafeArea()
                if let song = player.currentSong {
                    if raw.isEmpty {
                        ContentUnavailableView {
                            Label("The words are yours to add", systemImage: "quote.bubble")
                        } description: { Text("Attach an LRC file or paste plain lyrics. Everything stays offline.") } actions: {
                            Button("Attach lyrics") { attaching = true }.buttonStyle(.borderedProminent)
                            Button("Write or paste lyrics") { editing = true }
                        }
                    } else if parsed.isSynchronized {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 28) {
                                    Text(song.artist.uppercased()).font(.caption.bold()).tracking(2).foregroundStyle(Palette.accent).padding(.bottom, 12)
                                    ForEach(parsed.lines) { line in
                                        Button { player.seek(line.time); following = true } label: {
                                            Text(line.text.isEmpty ? "•••" : line.text)
                                                .font(.system(.title, design: .rounded, weight: .bold))
                                                .foregroundStyle(active == line.id ? .white : .white.opacity(0.52))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .contentShape(Rectangle())
                                        }.buttonStyle(.plain).id(line.id).accessibilityLabel("\(line.text), seek to \(line.time.clock)")
                                    }
                                }.padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 220)
                            }
                            .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in following = false })
                            .onChange(of: active) { _, value in
                                guard following, autoFollow, let value else { return }
                                if reduceMotion { proxy.scrollTo(value, anchor: .center) }
                                else { withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(value, anchor: .center) } }
                            }
                            .onChange(of: following) { _, value in if value, let active { withAnimation { proxy.scrollTo(active, anchor: .center) } } }
                            .onAppear { if let active { proxy.scrollTo(active, anchor: .center) } }
                        }
                    } else {
                        ScrollView { Text(parsed.plainText).font(.title3.weight(.medium)).lineSpacing(12).textSelection(.enabled).padding(28).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    if parsed.isSynchronized && !following && autoFollow {
                        Button("Follow lyrics", systemImage: "arrow.down.to.line") { following = true }.buttonStyle(.borderedProminent).tint(Palette.accent).foregroundStyle(Palette.background).padding(.bottom, 20)
                    }
                } else { ContentUnavailableView("Play a song to see lyrics", systemImage: "quote.bubble") }
            }
            .navigationTitle(player.currentSong?.title ?? "Lyrics").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Edit or paste lyrics", systemImage: "pencil") { editing = true }
                        Button("Attach LRC or text file", systemImage: "doc") { attaching = true }
                        Toggle("Follow automatically", isOn: $autoFollow)
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Lyric options").disabled(player.currentSong == nil)
                }
            }
            .task(id: "\(player.currentSong?.id ?? "")|\(library.revision)") { await loadLyrics() }
            .sheet(isPresented: $editing) { if let song = player.currentSong { LyricsEditor(song: song, initial: raw) } }
            .fileImporter(isPresented: $attaching, allowedContentTypes: [.item]) { result in
                guard let song = player.currentSong else { return }
                switch result {
                case .success(let url):
                    Task {
                        do {
                            let text = try await Task.detached {
                                let access = url.startAccessingSecurityScopedResource()
                                defer { if access { url.stopAccessingSecurityScopedResource() } }
                                return try LyricsParser.read(url)
                            }.value
                            try await saveLyrics(text, song: song, library: library)
                        } catch { self.error = error.localizedDescription }
                    }
                case .failure(let error): self.error = error.localizedDescription
                }
            }
            .alert("Lyrics", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }
    private func loadLyrics() async {
        raw = ""; parsed = LyricsParser.parse(""); following = true
        guard let song = player.currentSong else { return }
        let url = library.paths.lyricURL(song.id)
        do {
            let result = try await Task.detached { FileManager.default.fileExists(atPath: url.path) ? try LyricsParser.read(url) : "" }.value
            guard player.currentSong?.id == song.id else { return }
            raw = result; parsed = LyricsParser.parse(result)
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
private func saveLyrics(_ text: String, song: Song, library: LibraryModel) async throws {
    guard text.utf8.count <= 4_194_304 else { throw LibraryError.message("Lyrics are too large (maximum 4 MB).") }
    let url = library.paths.lyricURL(song.id)
    try await Task.detached { try text.write(to: url, atomically: true, encoding: .utf8) }.value
    try await library.db.setState("manualLyrics.\(song.id)", value: true)
    library.revision += 1
}

private struct LyricsEditor: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let song: Song
    @State private var text: String
    @State private var error: String?
    init(song: Song, initial: String) { self.song = song; _text = State(initialValue: initial) }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste plain text or LRC timestamps such as [00:12.50]. Saving an empty field clears the lyrics.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                TextEditor(text: $text).font(.body.monospaced()).padding(.horizontal, 8).accessibilityLabel("Lyrics text")
            }.navigationTitle("Edit lyrics").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) { Button("Save") { Task { do { try await saveLyrics(text, song: song, library: library); dismiss() } catch { self.error = error.localizedDescription } } } }
                }
                .alert("Could not save lyrics", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }
}
