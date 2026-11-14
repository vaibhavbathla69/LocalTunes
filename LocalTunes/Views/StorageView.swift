import SwiftUI

struct StorageView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var usage = StorageUsage()
    @State private var busy = false
    @State private var confirming = false
    @State private var message: String?
    var body: some View {
        List {
            Section("Space used") {
                row("Music", usage.music)
                row("Originals in Import", usage.originals)
                row("Artwork", usage.artwork)
                row("Library data", usage.library)
            }
            Section("Verified imported originals") {
                row("Reclaimable", usage.reclaimable)
                Text("Only originals with a byte-for-byte verified copy in your music library can be removed. Unimported files and lyric sidecars are kept.").font(.footnote).foregroundStyle(.secondary)
                ForEach(usage.verified, id: \.self) { Text($0.lastPathComponent).font(.caption).lineLimit(2) }
                Button("Remove verified originals", role: .destructive) { confirming = true }
                    .disabled(busy || usage.verified.isEmpty || library.isImporting)
            }
            if busy { ProgressView("Checking complete file contents…") }
            if let message { Text(message).font(.footnote) }
            Button("Check storage again") { Task { await scan() } }.disabled(busy || library.isImporting)
        }.navigationTitle("Storage").task { await scan() }
            .confirmationDialog("Remove verified originals from Import?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Remove originals", role: .destructive) {
                    Task {
                        guard !library.isImporting else { return }
                        busy = true
                        do {
                            let count = try await StorageService(paths: library.paths, db: library.db).removeVerified(usage.verified)
                            message = "Removed \(count) original files."
                        } catch { message = error.localizedDescription }
                        busy = false
                        await scan()
                    }
                }
            } message: { Text("The managed music copies stay in your library. Each original is verified again before removal.") }
    }
    private func row(_ title: String, _ bytes: Int64) -> some View {
        LabeledContent(title, value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
    }
    private func scan() async {
        guard !busy, !library.isImporting else { return }
        busy = true
        do { usage = try await StorageService(paths: library.paths, db: library.db).inspect() }
        catch { message = error.localizedDescription }
        busy = false
    }
}
