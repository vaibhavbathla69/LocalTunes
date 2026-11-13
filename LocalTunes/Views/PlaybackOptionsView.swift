import SwiftUI

struct PlaybackOptionsView: View {
    @EnvironmentObject private var player: PlaybackService
    var body: some View {
        Form { PlaybackOptionsSections() }.navigationTitle("Playback")
    }
}

struct PlaybackOptionsSections: View {
    @EnvironmentObject private var player: PlaybackService
    var body: some View {
        Section {
            Picker("Crossfade", selection: Binding(get: { Int(player.crossfadeSeconds) }, set: { value in Task { await player.setCrossfade(Double(value)) } })) {
                Text("Off").tag(0)
                ForEach(1...8, id: \.self) { Text("\($0) seconds").tag($0) }
            }.accessibilityIdentifier("playback.crossfade")
        } header: { Text("Transitions") } footer: { Text("Off keeps album transitions intact. Crossfade overlaps consecutive songs.") }
        Section {
            Toggle("Volume balancing", isOn: Binding(get: { player.volumeBalancing }, set: { enabled in Task { await player.setVolumeBalancing(enabled) } }))
                .accessibilityIdentifier("playback.balancing")
            if let progress = player.analysisProgress {
                HStack { ProgressView(); Text(progress); Spacer(); Button("Cancel") { player.cancelAnalysis() } }
            } else { Button("Measure library volume") { player.analyzeLibrary() } }
        } header: { Text("Volume") } footer: { Text("Measures audio on this phone and reduces louder tracks. Your files stay unchanged.") }
    }
}

struct SleepTimerView: View {
    @EnvironmentObject private var player: PlaybackService
    @Environment(\.dismiss) private var dismiss
    @State private var customMinutes = 30
    var body: some View {
        NavigationStack {
            List {
                if player.sleepTimer.isActive {
                    Section {
                        if let deadline = player.sleepTimer.deadline { LabeledContent("Stops at") { Text(deadline, style: .time) } }
                        else { Text("Stops at end of song") }
                        Button("Cancel timer", role: .destructive) { Task { await player.setSleepTimer(); dismiss() } }.accessibilityIdentifier("sleep.cancel")
                    }
                }
                Section {
                    ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                        Button("\(minutes) minutes") { Task { await player.setSleepTimer(minutes: minutes); dismiss() } }.accessibilityIdentifier("sleep.\(minutes)")
                    }
                    Button("End of song") { Task { await player.setSleepTimer(endOfSong: true); dismiss() } }.disabled(player.currentSong == nil).accessibilityIdentifier("sleep.endOfSong")
                }
                Section("Custom") {
                    Stepper("\(customMinutes) minutes", value: $customMinutes, in: 1...240, step: 1)
                    Button("Start timer") { Task { await player.setSleepTimer(minutes: customMinutes); dismiss() } }
                }
            }.navigationTitle("Sleep timer").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
