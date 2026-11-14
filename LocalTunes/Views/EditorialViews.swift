import SwiftUI
import MediaPlayer

/// Animated, cover-derived color fields compatible with iOS 17.
struct ImmersiveArtworkBackground: View {
    var song: Song?
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var phase
    @State private var colors = ArtworkColors.default
    @AppStorage("theme.motion") private var motion = true
    @AppStorage("theme.blur") private var blur = 85.0
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion || !motion || phase != .active)) { time in
            GeometryReader { geometry in
                let drift = (reduceMotion || !motion) ? 0.0 : sin(time.date.timeIntervalSinceReferenceDate / 9)
                ZStack {
                    colors.primary.color
                    Ellipse().fill(colors.secondary.color)
                        .frame(width: geometry.size.width * 1.5, height: geometry.size.height * 0.7)
                        .offset(x: drift * 100, y: -geometry.size.height * 0.22)
                    Ellipse().fill(colors.primary.color.opacity(0.7))
                        .offset(x: -drift * 120, y: geometry.size.height * 0.35)
                }.blur(radius: reduceTransparency ? 0 : blur)
                    .overlay(Color.black.opacity(0.48))
                    .overlay(LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .top, endPoint: .bottom))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
            .task(id: song?.artworkPath ?? song?.id ?? "") {
                let url = song?.artworkPath.map { library.paths.documents.appendingPathComponent($0) }
                let next = await ArtworkColorLoader.shared.colors(artwork: url, seed: song?.album ?? "LocalTunes")
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 1.5)) { colors = next }
            }
    }
}

struct SystemVolumeControl: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.tintColor = UIColor(Palette.accent)
        return view
    }
    func updateUIView(_ view: MPVolumeView, context: Context) { }
}

struct AudioFormatBadge: View {
    let song: Song
    private var lossless: Bool { ["flac", "alac"].contains((song.relativePath as NSString).pathExtension.lowercased()) }
    var body: some View {
        if lossless {
            Label("Lossless file", systemImage: "waveform")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
                .accessibilityLabel("Lossless source file")
        }
    }
}

struct BrowseView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var albums: [GroupSummary] = []
    @State private var songs: [Song] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if !songs.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeading(title: "In your collection")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 16) {
                                ForEach(songs) { song in EditorialAlbumCard(song: song) }
                            }.scrollTargetLayout()
                        }.scrollTargetBehavior(.viewAligned).scrollClipDisabled()
                    }
                }
                HStack(spacing: 12) {
                    NavigationLink { GroupListView(kind: .artist).navigationTitle("Artists") } label: { browseLink("Artists", icon: "person.2.fill") }
                    NavigationLink { GroupListView(kind: .genre).navigationTitle("Genres") } label: { browseLink("Genres", icon: "guitars.fill") }
                }
                SectionHeading(title: "Albums")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 18)], alignment: .leading, spacing: 26) {
                    ForEach(albums) { GroupCard(group: $0, kind: .album) }
                }
                if albums.isEmpty {
                    ContentUnavailableView("Your albums live here", systemImage: "square.stack", description: Text("Import music to explore your collection."))
                }
            }.padding(20)
        }.background(Palette.background).navigationTitle("Browse")
            .toolbarBackground(.regularMaterial, for: .navigationBar)
            .toolbar { ImportMenu() }
            .task(id: library.revision) {
                do {
                    albums = try await library.db.groups(.album)
                    let recent = try await library.db.songs(sort: .added, limit: 100)
                    var seen = Set<String>()
                    songs = Array(recent.filter { seen.insert($0.album).inserted }.prefix(8))
                } catch { library.errorMessage = error.localizedDescription }
            }
    }
    private func browseLink(_ title: String, icon: String) -> some View {
        HStack { Image(systemName: icon); Text(title).font(.headline); Spacer(); Image(systemName: "chevron.right").font(.caption.bold()) }
            .padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct EditorialAlbumCard: View {
    let song: Song
    @ScaledMetric private var size: CGFloat = 280
    var body: some View {
        NavigationLink { AlbumDetailView(albumName: AlbumIdentity.key(for: song)) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ArtworkView(song: song, size: size, fullSize: true, cornerRadius: 0)
                VStack(alignment: .leading, spacing: 6) {
                    Text(song.album).font(.title2.bold()).lineLimit(2)
                    Text(song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    AudioFormatBadge(song: song)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(width: size).background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
}
