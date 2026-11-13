import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryModel
    @AppStorage("lyricsAutoFollow") private var lyricsAutoFollow = true
    @State private var preparingBackup = false
    @State private var backupReady = false
    @State private var auditMessage: String?
    @State private var auditing = false
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "waveform").font(.largeTitle).foregroundStyle(Palette.accent)
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "LocalTunes").font(.title.bold())
                }.padding(.vertical, 12)
            }
            Section("On this iPhone") {
                LabeledContent("Songs", value: "\(library.songCount)")
                LabeledContent("Indexed audio", value: ByteCountFormatter.string(fromByteCount: library.musicBytes, countStyle: .file))
                LabeledContent("Available storage", value: ByteCountFormatter.string(fromByteCount: library.availableBytes, countStyle: .file))
                Text("Artwork, lyrics, database and source copies in Import use additional space. Imports need room for an app-owned copy. Duplicate detection compares complete file hashes.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Import music") {
                Button("Choose audio and lyric files", systemImage: "doc.badge.plus") { library.importFiles = true }
                Button("Choose a folder", systemImage: "folder.badge.plus") { library.importFolder = true }
                Button("Scan shared Import folder", systemImage: "arrow.triangle.2.circlepath") { library.scanInbox() }
                Text("In Files: On My iPhone → LocalTunes → Import. With Apple Devices or Finder, copy a music folder into Import, then scan it here. Source files are kept; remove the Import copies after checking playback to reclaim storage. Do not move or rename managed files in Music or LibraryData.").font(.footnote).foregroundStyle(.secondary)
            }.disabled(library.isImporting)
            Section("Lyrics") {
                Toggle("Follow synchronized lyrics", isOn: $lyricsAutoFollow)
                Text("LRC sidecars match by filename, title, or Artist - Title. Ambiguous matches need manual attachment. In Now Playing, open Lyrics to attach or edit text.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink("Playback", systemImage: "slider.horizontal.3") { PlaybackOptionsView() }
                NavigationLink("Listening stats", systemImage: "chart.bar") { ListeningStatsView() }
            }
            Section("Library care") {
                Button(auditing ? "Checking files…" : "Check for missing audio files", systemImage: "checkmark.shield") {
                    auditing = true
                    Task {
                        do {
                            let ids = try await library.db.allIDs()
                            var missing = 0
                            for id in ids {
                                if let song = try await library.db.song(id), !FileManager.default.fileExists(atPath: library.paths.audioURL(for: song).path) { missing += 1 }
                            }
                            auditMessage = missing == 0 ? "All \(ids.count) indexed audio files are present." : "\(missing) audio files are missing. Reimport the original files to repair them. No index entries have been removed."
                        } catch { auditMessage = error.localizedDescription }
                        auditing = false
                    }
                }.disabled(auditing)
                Button(preparingBackup ? "Preparing index backup…" : "Prepare index backup for file sharing", systemImage: "externaldrive") {
                    preparingBackup = true
                    Task {
                        do {
                            try await library.db.backup(to: library.paths.documents.appendingPathComponent("LibraryIndex-backup.sqlite"))
                            backupReady = true
                        } catch { library.errorMessage = error.localizedDescription }
                        preparingBackup = false
                    }
                }.disabled(preparingBackup || library.isImporting)
                Text("The backup button saves a consistent index snapshot as LibraryIndex-backup.sqlite in Documents. Copy it, Music, and LibraryData/Artwork and Lyrics to your computer. The index does not contain audio. See README for restoration instructions. Automatic cloud backup is disabled for this library.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("App information") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")
                Text("No accounts, analytics, online lyrics or network playback. Imported music is never uploaded by LocalTunes. Files providers may download files you select; use On My iPhone for an entirely offline import.").font(.footnote).foregroundStyle(.secondary)
                Text("Free Apple Account signing normally expires after 7 days. Refresh with the same Apple Account and app identifier. Install updates over the existing app; deleting the app removes its library.").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Settings")
            .task { await library.refresh() }
            .alert("Index backup ready", isPresented: $backupReady) { Button("OK") { } } message: { Text("Copy LibraryIndex-backup.sqlite, Music, Artwork and Lyrics using Files or Apple Devices. Keep your original music files too.") }
            .alert("Library check", isPresented: Binding(get: { auditMessage != nil }, set: { if !$0 { auditMessage = nil } })) { Button("OK") { auditMessage = nil } } message: { Text(auditMessage ?? "") }
    }
}
