import SwiftUI

struct ArtistMergeView: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let target: String
    @State private var artists: [GroupSummary] = []
    @State private var search = ""
    @State private var source: String?
    @State private var error: String?
    @State private var saving = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(artists.filter { search.isEmpty || $0.name.localizedStandardContains(search) }) { artist in
                        Button(artist.name) { source = artist.name }.accessibilityIdentifier("artist.merge.\(artist.name)")
                    }
                } header: { Text("Merge into \(target)") } footer: { Text("Choose another spelling of this artist. Original song credits stay unchanged.") }
            }.disabled(saving).navigationTitle("Merge artist").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search).toolbar { Button("Done") { dismiss() }.disabled(saving) }
                .task {
                    do { artists = try await library.db.groups(.artist).filter { ArtistCredits.key($0.name) != ArtistCredits.key(target) } }
                    catch { self.error = error.localizedDescription }
                }
                .confirmationDialog("Merge \(source ?? "") into \(target)?", isPresented: Binding(get: { source != nil }, set: { if !$0 { source = nil } }), titleVisibility: .visible) {
                    if let source {
                        Button("Merge artist") { Task {
                            saving = true
                            do { try await library.db.mergeArtist(source, into: target); library.revision += 1; dismiss() }
                            catch { self.error = error.localizedDescription }
                            saving = false
                        } }
                    }
                }
                .alert("Artist", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }
}

struct ArtistCreditsView: View {
    @Environment(\.dismiss) private var dismiss
    let song: Song
    var body: some View {
        NavigationStack {
            List {
                ForEach(ArtistCredits.names(artist: song.artist, title: song.title), id: \.self) { name in
                    NavigationLink(name) { ArtistDetailView(name: name) }
                }
            }.navigationTitle("Artists").toolbar { Button("Done") { dismiss() } }
        }
    }
}
