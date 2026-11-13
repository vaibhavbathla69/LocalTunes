import SwiftUI

extension ArtworkColors.RGB {
    var color: Color { Color(red: red, green: green, blue: blue) }
}

struct AlbumGradient: View {
    var colors: ArtworkColors
    var strength: Double = 0.7
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Palette.background
                LinearGradient(colors: [colors.primary.color.opacity(strength), colors.secondary.color.opacity(strength * 0.45), Palette.background], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [colors.secondary.color.opacity(strength * 0.55), .clear], center: .topTrailing,
                               startRadius: 0, endRadius: max(proxy.size.width, proxy.size.height) * 0.8)
                LinearGradient(colors: [.clear, Palette.background.opacity(0.82)], startPoint: .top, endPoint: .bottom)
            }.frame(width: proxy.size.width, height: proxy.size.height)
        }.allowsHitTesting(false)
    }
}

struct ArtworkBackdrop: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var song: Song?
    var strength: Double = 0.7
    @State private var colors = ArtworkColors.default
    var body: some View {
        AlbumGradient(colors: colors, strength: strength)
            .task(id: song?.artworkPath ?? song?.id ?? "empty") {
                let url = song?.artworkPath.map { library.paths.documents.appendingPathComponent($0) }
                let value = await ArtworkColorLoader.shared.colors(artwork: url, seed: "\(song?.album ?? "LocalTunes")|\(song?.artist ?? "")")
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.65)) { colors = value }
            }
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt = "Songs, artists, albums"
    @FocusState private var focused: Bool
    var focusRequest = 0
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.title3.weight(.semibold)).foregroundStyle(Palette.muted)
            TextField(prompt, text: $text).font(.body.weight(.medium)).foregroundStyle(.white)
                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                .focused($focused).onSubmit { focused = false }
                .accessibilityLabel(prompt).accessibilityIdentifier("localSearchField")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted).frame(width: 32, height: 36) }.accessibilityLabel("Clear search")
            }
            if focused {
                Button("Done") { focused = false }.font(.subheadline.weight(.semibold)).accessibilityIdentifier("search.dismissKeyboard")
            }
        }.padding(.horizontal, 16).padding(.vertical, 9).frame(minHeight: 54)
            .background(.white.opacity(0.085), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(focused ? 0.3 : 0.05), lineWidth: 1))
            .task(id: focusRequest) { if focusRequest > 0 { focused = true } }
    }
}

struct FilterPill: View {
    let title: String
    var selected = false
    var icon: String? = nil
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }.font(.subheadline.weight(.semibold)).padding(.horizontal, 18).padding(.vertical, 11)
                .foregroundStyle(selected ? Palette.background : .white)
                .background(selected ? Palette.accent : .white.opacity(0.08), in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct RoundIconButton: View {
    var symbol: String
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 44, height: 44).background(.white.opacity(0.09), in: Circle()) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }
}

struct CollectionCover: View {
    var song: Song?
    var symbol = "music.note.list"
    var size: CGFloat = 72
    var seed = "Collection"
    var body: some View {
        ZStack {
            if let song { ArtworkView(song: song, size: size, fullSize: size > 100) }
            else {
                AlbumGradient(colors: .fallback(seed: seed), strength: 1)
                Image(systemName: symbol).font(.system(size: size * 0.34, weight: .medium)).foregroundStyle(.white)
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size > 100 ? 16 : 10)).accessibilityHidden(true)
    }
}

extension View {
    @ViewBuilder func collectionNavigationTitle(_ title: String, embedded: Bool) -> some View {
        if embedded { self } else { self.navigationTitle(title).navigationBarTitleDisplayMode(.inline) }
    }
}
