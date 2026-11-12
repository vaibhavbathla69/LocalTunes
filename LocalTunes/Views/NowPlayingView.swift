import SwiftUI
import MediaPlayer
import AVKit
import UIKit

struct NowPlayingView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlaybackService
    @Environment(\.dismiss) private var dismiss
    @State private var lyrics = false
    @State private var queue = false
    @State private var scrubbing = false
    @State private var scrubPosition: Double = 0
    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack {
                    Palette.background.ignoresSafeArea()
                    if let song = player.currentSong {
                        ArtworkView(song: song, size: max(proxy.size.width, proxy.size.height), fullSize: true)
                            .blur(radius: 85).opacity(0.3).allowsHitTesting(false).ignoresSafeArea()
                        ScrollView {
                            VStack(spacing: 26) {
                                Text("FROM YOUR COLLECTION").font(.caption.weight(.semibold)).tracking(2.5).foregroundStyle(.secondary)
                                ArtworkView(song: song, size: min(350, max(180, min(proxy.size.width - 64, proxy.size.height * 0.44))), fullSize: true)
                                    .shadow(color: .black.opacity(0.4), radius: 30, y: 18).padding(.vertical, 8)
                                HStack(alignment: .center, spacing: 16) {
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(song.title).font(.title2.bold()).lineLimit(2)
                                        Text(song.artist).font(.title3).foregroundStyle(.secondary).lineLimit(2)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Button { Task { await library.favourite(song) } } label: {
                                        Image(systemName: song.isFavourite ? "heart.fill" : "heart").font(.title2).foregroundStyle(song.isFavourite ? Palette.accent : .white).frame(width: 44, height: 44)
                                    }.accessibilityLabel(song.isFavourite ? "Remove favourite" : "Add favourite")
                                }
                                VStack(spacing: 0) {
                                    Slider(value: Binding(get: { scrubbing ? scrubPosition : min(player.position, max(player.duration, 1)) }, set: { scrubPosition = $0 }), in: 0...max(player.duration, 1)) { editing in
                                        scrubbing = editing
                                        if !editing { player.seek(scrubPosition) }
                                    }.tint(.white).accessibilityLabel("Playback position").accessibilityValue(player.position.clock)
                                    HStack { Text((scrubbing ? scrubPosition : player.position).clock); Spacer(); Text("−" + max(0, player.duration - (scrubbing ? scrubPosition : player.position)).clock) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                HStack(spacing: 0) {
                                    Button { Task { await player.toggleShuffle() } } label: { Image(systemName: "shuffle").font(.title3).frame(maxWidth: .infinity, minHeight: 44).foregroundStyle(player.queue.shuffle ? Palette.accent : .secondary) }.accessibilityLabel(player.queue.shuffle ? "Shuffle on" : "Shuffle off")
                                    Button { Task { await player.previous() } } label: { Image(systemName: "backward.end.fill").font(.system(size: 28)).frame(maxWidth: .infinity, minHeight: 54) }.accessibilityLabel("Previous song")
                                    Button { Task { await player.toggle() } } label: {
                                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 30, weight: .semibold)).foregroundStyle(Palette.background).frame(width: 76, height: 76).background(.white, in: Circle())
                                    }.accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                                        .accessibilityIdentifier("nowPlaying.playPause")
                                    Button { Task { await player.next() } } label: { Image(systemName: "forward.end.fill").font(.system(size: 28)).frame(maxWidth: .infinity, minHeight: 54) }.accessibilityLabel("Next song")
                                    Button { Task { await player.cycleRepeat() } } label: { Image(systemName: player.queue.repeatMode.symbol).font(.title3).frame(maxWidth: .infinity, minHeight: 44).foregroundStyle(player.queue.repeatMode != .off ? Palette.accent : .secondary) }.accessibilityLabel("Repeat \(player.queue.repeatMode.rawValue)")
                                }
                                HStack {
                                    Button { lyrics = true } label: { Label("Lyrics", systemImage: "quote.bubble").font(.subheadline.weight(.semibold)).padding(.horizontal, 18).padding(.vertical, 12).background(.white.opacity(0.08), in: Capsule()) }.accessibilityLabel("Open lyrics").accessibilityIdentifier("nowPlaying.lyrics")
                                    Spacer()
                                    RoutePicker().frame(width: 44, height: 44).accessibilityLabel("Choose audio output")
                                    Spacer()
                                    Button { queue = true } label: { Image(systemName: "list.bullet").font(.title3).frame(width: 44, height: 44) }.accessibilityLabel("Open playback queue").accessibilityIdentifier("nowPlaying.queue")
                                }
                                Text(song.album).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }.padding(.horizontal, 28).padding(.bottom, 24).frame(maxWidth: 560).frame(maxWidth: .infinity)
                        }
                    } else { ContentUnavailableView("Nothing playing", systemImage: "music.note") }
                }.frame(width: proxy.size.width, height: proxy.size.height)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }.accessibilityLabel("Close Now Playing") }
                ToolbarItem(placement: .principal) { Text("NOW PLAYING").font(.caption.weight(.bold)).tracking(2) }
            }
            .sheet(isPresented: $lyrics) { LyricsView() }
            .sheet(isPresented: $queue) { QueueView() }
        }.tint(.white).preferredColorScheme(.dark)
    }
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white; view.activeTintColor = UIColor(Palette.accent)
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { }
}

struct QueueView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlaybackService
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("\(player.queue.entries.count) queue entries • drag to reorder") {
                    ForEach(player.queue.entries) { entry in QueueSongRow(entry: entry) }
                        .onDelete { offsets in
                            let ids = Set(offsets.compactMap { player.queue.entries.indices.contains($0) ? player.queue.entries[$0].id : nil })
                            Task { await player.remove(entryIDs: ids) }
                        }
                        .onMove { from, to in Task { await player.move(from: from, to: to) } }
                }
            }.navigationTitle("Your queue").toolbar { ToolbarItem(placement: .topBarLeading) { EditButton() }; ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
                .overlay { if player.queue.entries.isEmpty { ContentUnavailableView("The queue is clear", systemImage: "list.bullet", description: Text("Long-press any song to play next or add to queue.")) } }
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
                ArtworkView(song: song, size: 44)
                VStack(alignment: .leading, spacing: 4) { Text(song?.title ?? "Loading…").lineLimit(1); Text(song?.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                if entry.id == player.queue.currentID { Image(systemName: "waveform").foregroundStyle(Palette.accent) }
            }
        }.buttonStyle(.plain)
            .task(id: entry.songID) { do { song = try await library.db.song(entry.songID) } catch { library.errorMessage = error.localizedDescription } }
    }
}
