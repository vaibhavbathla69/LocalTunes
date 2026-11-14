import SwiftUI
import UniformTypeIdentifiers

struct AlbumArtworkView: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let album: String
    @State private var choosing = false
    @State private var image: Data?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                if let image, let preview = UIImage(data: image) { Image(uiImage: preview).resizable().scaledToFit().frame(height: 240) }
                Button("Choose album cover", systemImage: "photo") { choosing = true }
                Text("Applies the cover to every song in this album. Source audio files are not modified.").font(.footnote).foregroundStyle(.secondary)
                if busy { ProgressView("Saving artwork…") }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Album artwork").disabled(busy)
                .toolbar {
                    Button("Cancel") { dismiss() }.disabled(busy)
                    Button("Apply to album") { Task { await apply() } }.disabled(image == nil || busy)
                }
                .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) { result in
                    do {
                        let url = try result.get(); let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 20 * 1024 * 1024 else { throw LibraryError.message("Choose an image under 20 MB.") }
                        image = try Data(contentsOf: url)
                    } catch { self.error = error.localizedDescription }
                }
        }
    }
    private func apply() async {
        guard let image else { return }
        busy = true
        do { try await library.applyAlbumArtwork(album, data: image); dismiss() }
        catch { self.error = error.localizedDescription }
        busy = false
    }
}

struct MissingArtworkView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var albums: [GroupSummary] = []
    var body: some View {
        List(albums) { album in NavigationLink(album.name) { AlbumDetailView(albumName: album.value) } }
            .navigationTitle("Missing artwork")
            .overlay { if albums.isEmpty { ContentUnavailableView("No missing covers", systemImage: "photo") } }
            .task(id: library.revision) {
                do { albums = try await library.db.albumsMissingArtwork() }
                catch { library.errorMessage = error.localizedDescription }
            }
    }
}
