import SwiftUI

struct SmartMixesView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var rules: [SmartMixRule] = []
    @State private var editing: SmartMixRule?
    var body: some View {
        List {
            ForEach(rules) { rule in
                HStack {
                    NavigationLink(rule.name) { SmartMixDetail(rule: rule) }
                    Button { editing = rule } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.borderless).accessibilityLabel("Edit " + rule.name)
                }
            }.onDelete { offsets in rules.remove(atOffsets: offsets); Task { await save() } }
            Button("Create smart mix", systemImage: "plus") { editing = SmartMixRule() }
        }.navigationTitle("Custom mixes")
            .task { do { rules = try await library.db.state("smart.mixes", as: [SmartMixRule].self) ?? [] } catch { library.errorMessage = error.localizedDescription } }
            .sheet(item: $editing) { rule in SmartMixEditor(rule: rule) { updated in
                if let index = rules.firstIndex(where: { $0.id == updated.id }) { rules[index] = updated } else { rules.append(updated) }
                Task { await save() }
            } }
    }
    private func save() async { do { try await library.db.setState("smart.mixes", value: rules) } catch { library.errorMessage = error.localizedDescription } }
}

private struct SmartMixEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryModel
    @State var rule: SmartMixRule
    var saved: (SmartMixRule) -> Void
    @State private var artists: [GroupSummary] = []
    @State private var genres: [GroupSummary] = []
    var body: some View {
        NavigationStack {
            Form {
                TextField("Mix name", text: $rule.name)
                Picker("Artist", selection: $rule.artist) { Text("Any").tag(""); ForEach(artists) { Text($0.name).tag($0.name) } }
                Picker("Genre", selection: $rule.genre) { Text("Any").tag(""); ForEach(genres) { Text($0.name).tag($0.name) } }
                TextField("From year", value: $rule.fromYear, format: .number.grouping(.never)).keyboardType(.numberPad)
                TextField("Through year", value: $rule.throughYear, format: .number.grouping(.never)).keyboardType(.numberPad)
                Toggle("Favourites only", isOn: $rule.favouritesOnly)
                Toggle("Never played", isOn: $rule.unplayedOnly)
                TextField("Not played for days", value: $rule.notPlayedDays, format: .number.grouping(.never)).keyboardType(.numberPad)
                Stepper("Up to \(rule.limit) songs", value: $rule.limit, in: 10...500, step: 10)
                Toggle("Random selection", isOn: $rule.shuffled)
                Text("Rules are combined. The selection refreshes from your library each time you open or play the mix.").font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("Smart mix").toolbar {
                Button("Cancel") { dismiss() }
                Button("Save") { saved(rule); dismiss() }.disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty || (rule.fromYear ?? 1) > (rule.throughYear ?? 9999) || (rule.fromYear ?? 1) < 1 || (rule.throughYear ?? 9999) > 9999 || (rule.notPlayedDays ?? 1) < 1)
            }.task { do { artists = try await library.db.groups(.artist); genres = try await library.db.groups(.genre) } catch { library.errorMessage = error.localizedDescription } }
        }
    }
}

private struct SmartMixDetail: View {
    @EnvironmentObject private var library: LibraryModel
    let rule: SmartMixRule
    @State private var songs: [Song] = []
    var body: some View {
        List {
            Button("Play mix", systemImage: "play.fill") { Task { do { let ids = try await library.db.smartMixIDs(rule); await library.player.play(ids: ids, shuffled: false) } catch { library.errorMessage = error.localizedDescription } } }.disabled(songs.isEmpty)
            ForEach(songs) { song in SongRow(song: song) { Task { await library.player.play(ids: songs.map(\.id), startingAt: song.id, shuffled: false) } } }
        }.navigationTitle(rule.name).task(id: library.revision) {
            do { var found: [Song] = []; for id in try await library.db.smartMixIDs(rule) { if let song = try await library.db.song(id) { found.append(song) } }; songs = found }
            catch { library.errorMessage = error.localizedDescription }
        }.overlay { if songs.isEmpty { ContentUnavailableView("No matching songs", systemImage: "line.3.horizontal.decrease.circle") } }
    }
}

struct SessionsView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var sessions: [ListeningSession] = []
    var body: some View {
        List {
            Section { Text("Sessions begin with this update. A break of 30 minutes starts a new session. The latest 10,000 track visits are shown.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(sessions) { session in NavigationLink { SessionDetail(session: session) } label: {
                VStack(alignment: .leading) { Text(session.started, format: .dateTime.month().day().hour().minute()).font(.headline); Text("\(session.visits.count) tracks / \(session.seconds.clock)").foregroundStyle(.secondary) }
            } }
        }.navigationTitle("Listening sessions").task { await library.player.flushListening(); do { sessions = try await library.db.listeningSessions() } catch { library.errorMessage = error.localizedDescription } }
    }
}

private struct SessionDetail: View {
    @EnvironmentObject private var library: LibraryModel
    let session: ListeningSession
    @State private var available: Set<String> = []
    @State private var saving = false
    @State private var name = ""
    var body: some View {
        List {
            Button("Save session as playlist", systemImage: "plus") { saving = true }.disabled(available.isEmpty)
            ForEach(session.visits) { visit in
                Button { Task { await library.player.play(ids: session.visits.map(\.songID).filter { available.contains($0) }, startingAt: visit.songID, shuffled: false) } } label: {
                    VStack(alignment: .leading) { Text(visit.title); Text(visit.artist).font(.caption).foregroundStyle(.secondary) }
                }.disabled(!available.contains(visit.songID))
            }
        }.navigationTitle("Session").task { do { available = Set(try await library.db.allIDs()) } catch { library.errorMessage = error.localizedDescription } }
            .alert("Save session", isPresented: $saving) {
                TextField("Playlist name", text: $name)
                Button("Save") { Task { let title = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !title.isEmpty else { return }; await library.savePlaylists(library.playlists + [Playlist(name: title, songIDs: session.visits.map(\.songID).filter { available.contains($0) })]) } }
                Button("Cancel", role: .cancel) { }
            }
    }
}

struct BookmarksView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlaybackService
    @State private var bookmarks: [PlaybackBookmark] = []
    @State private var name = ""
    @State private var adding = false
    @State private var position: Double = 0
    @State private var capturedSong: Song?
    @State private var busy = false
    var body: some View {
        List {
            if let song = player.currentSong {
                Section(song.title) {
                    Button("Bookmark current position", systemImage: "bookmark") { capturedSong = song; position = player.position; name = player.position.clock; adding = true }
                    Button(player.repeatA.map { "A: " + $0.clock } ?? "Set loop start A") { player.markRepeatA() }
                    Button(player.repeatB.map { "B: " + $0.clock } ?? "Set loop end B") { player.markRepeatB() }.disabled(player.repeatA == nil || player.position < (player.repeatA ?? 0) + 0.25)
                    if player.repeatA != nil { Button("Clear A-B loop", role: .destructive) { player.clearSectionRepeat() } }
                    Text("A-B repeat loops a passage in the current song. Changing tracks clears the loop.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(bookmarks) { bookmark in
                Button { Task {
                    do {
                        guard try await library.db.song(bookmark.songID) != nil else { throw LibraryError.message("This song is no longer in your library.") }
                        await player.play(ids: [bookmark.songID], shuffled: false); player.seek(bookmark.seconds)
                    } catch { library.errorMessage = error.localizedDescription }
                } } label: { HStack { Text(bookmark.title); Spacer(); Text(bookmark.seconds.clock).foregroundStyle(.secondary) } }
            }.onDelete { offsets in bookmarks.remove(atOffsets: offsets); Task { await save() } }
        }.disabled(busy).navigationTitle("Bookmarks & repeat")
            .task { do { bookmarks = try await library.db.state("playback.bookmarks", as: [PlaybackBookmark].self) ?? [] } catch { library.errorMessage = error.localizedDescription } }
            .alert("Bookmark", isPresented: $adding) {
                TextField("Name", text: $name)
                Button("Save") { if let song = capturedSong { bookmarks.append(PlaybackBookmark(songID: song.id, title: name.isEmpty ? song.title : name, seconds: position)); Task { await save() } } }
                Button("Cancel", role: .cancel) { }
            }
    }
    private func save() async { busy = true; defer { busy = false }; do { try await library.db.setState("playback.bookmarks", value: bookmarks) } catch { library.errorMessage = error.localizedDescription } }
}
