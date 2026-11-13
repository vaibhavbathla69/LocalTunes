import SwiftUI
import MediaPlayer
import AVKit
import UIKit

struct NowPlayingView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlaybackService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lyrics = false
    @State private var queue = false
    @State private var album: AlbumDestination?
    @State private var timer = false
    @State private var editing = false
    @State private var playbackOptions = false
    @State private var artistName: String?
    @State private var options = false
    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    if let song = player.currentSong {
                        VStack(spacing: 22) {
                            Button { album = AlbumDestination(name: song.album) } label: {
                                HStack(spacing: 7) { Text(song.album).lineLimit(1); Image(systemName: "chevron.right").font(.caption2.bold()) }.font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Open album \(song.album)").accessibilityIdentifier("nowPlaying.album")
                            ArtworkView(song: song, size: max(130, min(350, min(proxy.size.width - 52, proxy.size.height * 0.39))), fullSize: true, cornerRadius: 12)
                                .shadow(color: .black.opacity(0.35), radius: 28, y: 16)
                                .scaleEffect(player.isPlaying ? 1 : 0.96)
                                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: player.isPlaying)
                                .padding(.vertical, 10)
                            trackDetails(song)
                            PlaybackTimeline()
                            transport
                            HStack {
                                Button { lyrics = true } label: { Label("Lyrics", systemImage: "quote.bubble.fill").font(.subheadline.bold()).padding(.horizontal, 17).frame(height: 44).background(.white.opacity(0.13), in: Capsule()) }
                                    .accessibilityLabel("Open lyrics").accessibilityIdentifier("nowPlaying.lyrics")
                                Spacer(minLength: 8)
                                RoutePicker().frame(width: 44, height: 44).accessibilityLabel("Choose audio output")
                                Spacer(minLength: 8)
                                Button { queue = true } label: { Image(systemName: "list.bullet").font(.title3).frame(width: 48, height: 44).background(.white.opacity(0.13), in: Capsule()) }
                                    .accessibilityLabel("Open playback queue").accessibilityIdentifier("nowPlaying.queue")
                            }
                        }.padding(.horizontal, 26).padding(.top, 12).padding(.bottom, 32).frame(maxWidth: 540).frame(maxWidth: .infinity)
                    } else { ContentUnavailableView("Nothing playing", systemImage: "music.note") }
                }.frame(width: proxy.size.width, height: proxy.size.height)
            }
            .background { ArtworkBackdrop(song: player.currentSong, strength: 0.95).ignoresSafeArea() }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 44, height: 44) }.accessibilityLabel("Close Now Playing") }
                ToolbarItem(placement: .principal) { Text("NOW PLAYING").font(.caption.weight(.bold)).tracking(2) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { options = true } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .accessibilityLabel("Now Playing options").accessibilityIdentifier("nowPlaying.options")
                }
            }
            .confirmationDialog("Now Playing", isPresented: $options, titleVisibility: .hidden) {
                        if let song = player.currentSong {
                            Button("View album", systemImage: "square.stack.fill") { album = AlbumDestination(name: song.album) }
                            Button(song.isFavourite ? "Remove favourite" : "Add favourite", systemImage: "heart") { Task { await library.favourite(song) } }
                            Button("View artist", systemImage: "person.fill") { artistName = song.artist }
                            Button("Edit details", systemImage: "pencil") { editing = true }
                        }
                        Button(player.sleepTimer.isActive ? "Sleep timer (on)" : "Sleep timer", systemImage: "moon.zzz") { timer = true }
                        Button("Playback settings", systemImage: "slider.horizontal.3") { playbackOptions = true }
                        Button("Queue", systemImage: "list.bullet") { queue = true }
                        Button("Show lyrics", systemImage: "quote.bubble") { lyrics = true }
            }
            .sheet(isPresented: $lyrics) { LyricsView() }
            .sheet(isPresented: $queue) { QueueView() }
            .sheet(isPresented: $timer) { SleepTimerView() }
            .sheet(isPresented: $editing) { if let song = player.currentSong { SongEditorView(song: song) } }
            .sheet(isPresented: $playbackOptions) {
                NavigationStack { PlaybackOptionsView().toolbar { Button("Done") { playbackOptions = false } } }
            }
            .sheet(item: Binding(get: { artistName.map { AlbumDestination(name: $0) } }, set: { artistName = $0?.name })) { destination in
                NavigationStack { ArtistDetailView(name: destination.name).toolbar { Button("Done") { artistName = nil } } }
            }
            .sheet(item: $album) { destination in
                NavigationStack {
                    AlbumDetailView(albumName: destination.name, accessibilityPrefix: "player.album")
                        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { album = nil }.accessibilityIdentifier("album.done") } }
                }
            }
        }.tint(.white).preferredColorScheme(.dark)
    }

    private func trackDetails(_ song: Song) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(song.title).font(.title2.weight(.heavy)).lineLimit(2).accessibilityIdentifier("nowPlaying.title")
                Text(song.artist).font(.body).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { Task { await library.favourite(song) } } label: {
                Image(systemName: song.isFavourite ? "heart.fill" : "heart").font(.title2).foregroundStyle(song.isFavourite ? Palette.accent : .white).frame(width: 44, height: 44)
            }.accessibilityLabel(song.isFavourite ? "Remove favourite" : "Add favourite")
        }
    }

    private var transport: some View {
        HStack(spacing: 0) {
            Button { Task { await player.toggleShuffle() } } label: { Image(systemName: "shuffle").font(.title3).frame(maxWidth: .infinity, minHeight: 48).foregroundStyle(player.queue.shuffle ? Palette.accent : .white.opacity(0.65)) }.accessibilityLabel(player.queue.shuffle ? "Shuffle on" : "Shuffle off")
            Button { Task { await player.previous() } } label: { Image(systemName: "backward.end.fill").font(.system(size: 29)).frame(maxWidth: .infinity, minHeight: 54) }.accessibilityLabel("Previous song")
            Button { Task { await player.toggle() } } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 29, weight: .semibold)).foregroundStyle(Palette.background).frame(width: 74, height: 74).background(.white, in: Circle()).shadow(color: .black.opacity(0.15), radius: 15, y: 6)
            }.accessibilityLabel(player.isPlaying ? "Pause" : "Play").accessibilityIdentifier("nowPlaying.playPause")
            Button { Task { await player.next() } } label: { Image(systemName: "forward.end.fill").font(.system(size: 29)).frame(maxWidth: .infinity, minHeight: 54) }.accessibilityLabel("Next song").accessibilityIdentifier("nowPlaying.next")
            Button { Task { await player.cycleRepeat() } } label: { Image(systemName: player.queue.repeatMode.symbol).font(.title3).frame(maxWidth: .infinity, minHeight: 48).foregroundStyle(player.queue.repeatMode != .off ? Palette.accent : .white.opacity(0.65)) }.accessibilityLabel("Repeat \(player.queue.repeatMode.rawValue)")
        }
    }
}

private struct PlaybackTimeline: View {
    @EnvironmentObject private var player: PlaybackService
    @State private var scrubbing = false
    @State private var value: Double = 0
    var body: some View {
        VStack(spacing: 0) {
            Slider(value: Binding(get: { scrubbing ? value : min(player.position, max(player.duration, 1)) }, set: { value = $0 }), in: 0...max(player.duration, 1)) { editing in
                scrubbing = editing
                if !editing { player.seek(value) }
            }.tint(.white).accessibilityLabel("Playback position").accessibilityValue(player.position.clock)
            HStack { Text((scrubbing ? value : player.position).clock); Spacer(); Text("−" + max(0, player.duration - (scrubbing ? value : player.position)).clock) }
                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
        }
    }
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white; view.activeTintColor = UIColor(Palette.accent); view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { }
}

struct QueueView: View {
    @EnvironmentObject private var player: PlaybackService
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("\(player.queue.entries.count) tracks") {
                    ForEach(player.queue.entries) { entry in QueueSongRow(entry: entry).listRowBackground(Color.white.opacity(0.05)).listRowSeparator(.hidden) }
                        .onDelete { offsets in
                            let ids = Set(offsets.compactMap { player.queue.entries.indices.contains($0) ? player.queue.entries[$0].id : nil })
                            Task { await player.remove(entryIDs: ids) }
                        }
                        .onMove { from, to in Task { await player.move(from: from, to: to) } }
                }
            }.scrollContentBackground(.hidden).background { ArtworkBackdrop(song: player.currentSong, strength: 0.45).ignoresSafeArea() }
                .navigationTitle("Queue").toolbar { ToolbarItem(placement: .topBarLeading) { EditButton() }; ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
                .overlay { if player.queue.entries.isEmpty { ContentUnavailableView("Queue empty", systemImage: "list.bullet") } }
        }
    }
}

private struct QueueSongRow: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlaybackService
    let entry: QueueEntry
    @State private var song: Song?
    var body: some View {
        Button { Task { await player.jump(to: entry.id) } } label: {
            HStack(spacing: 12) {
                ArtworkView(song: song, size: 48)
                VStack(alignment: .leading, spacing: 5) { Text(song?.title ?? "Loading…").font(.subheadline.bold()).lineLimit(1); Text(song?.artist ?? "").font(.caption).foregroundStyle(Palette.muted).lineLimit(1) }
                Spacer()
                if entry.id == player.queue.currentID { Image(systemName: "waveform").foregroundStyle(Palette.accent) }
            }.padding(.vertical, 6)
        }.buttonStyle(.plain).task(id: entry.songID) { do { song = try await library.db.song(entry.songID) } catch { library.errorMessage = error.localizedDescription } }
    }
}
