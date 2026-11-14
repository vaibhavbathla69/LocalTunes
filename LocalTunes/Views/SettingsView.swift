import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryModel
    @AppStorage("lyricsAutoFollow") private var lyricsAutoFollow = true
    @State private var preparingBackup = false
    @State private var backupReady = false
    @State private var auditMessage: String?
    @State private var auditing = false
    @State private var resettingArtists = false
    @State private var albumScan: Task<Void, Never>?
    @State private var albumProgress: String?
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Image("BrandMark")
                        .resizable().interpolation(.none).scaledToFit()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityHidden(true)
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "LocalTunes").font(.title.bold())
                }.padding(.vertical, 12)
            }
            Section {
                NavigationLink { PlaybackOptionsView() } label: { Label("Playback", systemImage: "slider.horizontal.3") }.accessibilityIdentifier("settings.playback")
                NavigationLink { ListeningStatsView() } label: { Label("Listening stats", systemImage: "chart.bar") }.accessibilityIdentifier("settings.stats")
            }
            Section("On this iPhone") {
                NavigationLink { StorageView() } label: { Label("Storage and import cleanup", systemImage: "internaldrive") }
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
            Section("Library care") {
                if let albumProgress {
                    HStack { ProgressView(); Text(albumProgress); Button("Cancel") { albumScan?.cancel() } }
                } else {
                    Button("Read missing album artists", systemImage: "person.crop.square") {
                        albumScan = Task { await scanAlbumArtists() }
                    }.disabled(library.isImporting)
                }
                NavigationLink { MissingArtworkView() } label: { Label("Albums missing artwork", systemImage: "photo") }
                if let progress = library.artistScanProgress {
                    HStack { ProgressView(); Text("Artist credits \(progress)"); Spacer(); Button("Cancel") { library.cancelArtistScan() } }
                }
                Button("Reset artist merges", systemImage: "arrow.uturn.backward") { resettingArtists = true }
                if let progress = library.yearScanProgress {
                    HStack { ProgressView(); Text(progress); Spacer(); Button("Cancel") { library.cancelYearScan() } }
                } else { Button("Read missing release years", systemImage: "calendar") { library.scanMissingYears() } }
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
            .confirmationDialog("Reset manual artist merges?", isPresented: $resettingArtists, titleVisibility: .visible) {
                Button("Reset merges") { Task {
                    do { try await library.db.resetArtistMerges(); library.revision += 1 }
                    catch { library.errorMessage = error.localizedDescription }
                } }
            } message: { Text("Restores artist groupings from the original credits. Songs and listening history stay unchanged.") }
            .task { await library.refresh() }
            .onDisappear { albumScan?.cancel() }
            .alert("Index backup ready", isPresented: $backupReady) { Button("OK") { } } message: { Text("Copy LibraryIndex-backup.sqlite, Music, Artwork and Lyrics using Files or Apple Devices. Keep your original music files too.") }
            .alert("Library check", isPresented: Binding(get: { auditMessage != nil }, set: { if !$0 { auditMessage = nil } })) { Button("OK") { auditMessage = nil } } message: { Text(auditMessage ?? "") }
    }
    private func scanAlbumArtists() async {
        albumProgress = "Reading album tags"
        defer { albumProgress = nil; albumScan = nil }
        do {
            let ids = try await library.db.allIDs()
            for (index, id) in ids.enumerated() {
                try Task.checkCancellation()
                albumProgress = "Album tags \(index + 1)/\(ids.count)"
                guard let song = try await library.db.song(id), song.albumArtist == nil else { continue }
                let url = library.paths.audioURL(for: song)
                if url.pathExtension.lowercased() == "flac" {
                    let tags = try await Task.detached { try FLACMetadata.read(url, includeArtwork: false) }.value
                    if let tags, tags["ALBUM"] == song.album, let artist = tags["ALBUMARTIST"] ?? tags["ALBUM_ARTIST"] {
                        try await library.db.fillAlbumArtist(song, artist: artist)
                    }
                } else {
                    let metadata = try await MetadataExtractor.extract(url, originalName: song.originalFilename)
                    if metadata.album == song.album, let artist = metadata.albumArtist { try await library.db.fillAlbumArtist(song, artist: artist) }
                }
            }
        } catch is CancellationError { }
        catch { library.errorMessage = error.localizedDescription }
        library.revision += 1
    }

}
