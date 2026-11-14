import SwiftUI

struct LyricTimingView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlaybackService
    @Environment(\.dismiss) private var dismiss
    let song: Song
    let raw: String
    @State private var text = ""
    @State private var times: [Double] = []
    @State private var offset = 0.0
    @State private var error: String?
    @State private var saving = false
    private var lines: [String] { text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    var body: some View {
        NavigationStack {
            Form {
                Section("Lyrics, one line per row") {
                    TextEditor(text: Binding(get: { text }, set: { text = $0; times = []; offset = 0 })).frame(minHeight: 180)
                }
                Section("Tap along") {
                    Text(times.count < lines.count ? lines[times.count] : "Every line is timed").font(.title3.bold())
                    HStack {
                        Button(player.isPlaying ? "Pause" : "Play") { Task { await player.toggle() } }
                        Text(player.position.clock).monospacedDigit()
                        Button("Stamp line") { times.append(player.position) }.disabled(times.count >= lines.count || player.currentSong?.id != song.id || (times.last ?? -1) >= player.position)
                    }
                    Button("Undo last stamp") { if !times.isEmpty { times.removeLast() } }.disabled(times.isEmpty)
                    Text("Play this song and tap Stamp line as each line begins. Editing the text resets stamps.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Timing adjustment") {
                    Stepper(String(format: "Shift all lines: %+.2f seconds", offset), value: $offset, in: -30...30, step: 0.1)
                    Text("Positive values show lyrics later. Negative values show them earlier.").font(.footnote).foregroundStyle(.secondary)
                    ForEach(Array(zip(lines, times).enumerated()), id: \.offset) { item in
                        HStack { Text(max(0, item.element.1 + offset).clock).monospacedDigit(); Text(item.element.0).lineLimit(2) }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Lyrics timing").disabled(saving)
                .toolbar {
                    Button("Cancel") { dismiss() }
                    Button("Save") { Task { await save() } }.disabled(lines.isEmpty || lines.count != times.count || saving)
                }
                .onAppear {
                    let parsed = LyricsParser.parse(raw)
                    if parsed.isSynchronized {
                        let entries = parsed.lines.flatMap { line in line.text.components(separatedBy: .newlines).filter { !$0.isEmpty }.map { ($0, line.time) } }
                        text = entries.map { $0.0 }.joined(separator: "\n"); times = entries.map { $0.1 }
                    }
                    else { text = raw }
                }
        }
    }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            let output = LyricTiming.lrc(lines: lines, times: times, offset: offset)
            guard output.utf8.count <= 4_194_304 else { throw LibraryError.message("Lyrics exceed 4 MB") }
            try output.write(to: library.paths.lyricURL(song.id), atomically: true, encoding: .utf8)
            try await library.db.setState("manualLyrics.\(song.id)", value: true)
            library.revision += 1; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
