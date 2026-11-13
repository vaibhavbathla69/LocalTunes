import SwiftUI
import UIKit
import Combine

enum Palette {
    static let background = Color(red: 0.045, green: 0.05, blue: 0.06)
    static let surface = Color(red: 0.1, green: 0.11, blue: 0.13)
    static let accent = Color(red: 0.70, green: 0.98, blue: 0.36)
    static let muted = Color.white.opacity(0.62)
}

actor ArtworkLoader {
    static let shared = ArtworkLoader()
    private let cache = NSCache<NSString, UIImage>()
    init() { cache.totalCostLimit = 40 * 1024 * 1024; cache.countLimit = 200 }
    func image(_ url: URL) -> UIImage? {
        let key = url.path as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
        return image
    }
}

struct ArtworkView: View {
    @EnvironmentObject private var library: LibraryModel
    var song: Song?
    var size: CGFloat = 52
    var fullSize = false
    var cornerRadius: CGFloat? = nil
    @State private var image: UIImage?
    private var placeholderColors: ArtworkColors { .fallback(seed: "\(song?.album ?? "LocalTunes")|\(song?.artist ?? "")") }

    var body: some View {
        ZStack {
            LinearGradient(colors: [placeholderColors.primary.color, placeholderColors.secondary.color, Palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else {
                if size > 100 {
                    Circle().stroke(.white.opacity(0.08), lineWidth: 1).padding(size * 0.12)
                    Circle().stroke(.white.opacity(0.07), lineWidth: size * 0.08).padding(size * 0.22)
                }
                Image(systemName: "waveform").font(.system(size: max(18, size * 0.25), weight: .light)).foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? (size > 100 ? 14 : 7)))
        .accessibilityHidden(true)
        .task(id: "\(song?.id ?? "")-\(fullSize)") {
            image = nil
            guard let path = song?.artworkPath else { return }
            let url = library.paths.documents.appendingPathComponent(fullSize ? path : path.replacingOccurrences(of: ".jpg", with: ".thumb.jpg"))
            let loaded = await ArtworkLoader.shared.image(url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

struct SongRow: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlaybackService
    let song: Song
    var positionLabel: String? = nil
    var accessibilityID: String? = nil
    var action: () -> Void
    @State private var deleting = false
    @State private var choosingPlaylist = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                if let positionLabel {
                    Text(positionLabel).font(.subheadline.monospacedDigit()).foregroundStyle(Palette.muted).lineLimit(1).minimumScaleFactor(0.65).frame(width: 34)
                } else { ArtworkView(song: song) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(song.title).font(.body.weight(.medium)).foregroundStyle(player.currentSong?.id == song.id ? Palette.accent : .white).lineLimit(1)
                    Text(song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if song.isFavourite { Image(systemName: "heart.fill").font(.caption).foregroundStyle(Palette.accent) }
                Text(song.duration.clock).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(song.title), \(song.artist), \(song.duration.clock)")
        .accessibilityIdentifier(accessibilityID ?? "song.\(song.title)")
        .contextMenu {
            Button("Play", systemImage: "play.fill", action: action)
            Button("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") { Task { await player.append(song.id, next: true) } }
            Button("Add to queue", systemImage: "text.badge.plus") { Task { await player.append(song.id, next: false) } }
            Button(song.isFavourite ? "Remove favourite" : "Favourite", systemImage: song.isFavourite ? "heart.slash" : "heart") { Task { await library.favourite(song) } }
            Button("Add to playlist", systemImage: "music.note.list") { choosingPlaylist = true }
            Button("Delete from library", systemImage: "trash", role: .destructive) { deleting = true }
        }
        .confirmationDialog("Delete ‘\(song.title)’? This removes the app's copy of the audio and lyrics.", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete song", role: .destructive) { Task { await library.delete(song) } }
        }
        .sheet(isPresented: $choosingPlaylist) { PlaylistPicker(songID: song.id) }
    }
}

struct ImportMenu: View {
    @EnvironmentObject private var library: LibraryModel
    var body: some View {
        Menu {
            Button("Audio and lyric files", systemImage: "doc.badge.plus") { library.importFiles = true }
            Button("Import a folder", systemImage: "folder.badge.plus") { library.importFolder = true }
            Button("Scan shared Import folder", systemImage: "arrow.triangle.2.circlepath") { library.scanInbox() }
        } label: { Image(systemName: "plus.circle.fill").font(.title3) }
        .disabled(library.isImporting).accessibilityLabel("Import music")
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title2.bold())
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Double {
    var clock: String {
        guard isFinite else { return "0:00" }
        let seconds = max(0, Int(self))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
