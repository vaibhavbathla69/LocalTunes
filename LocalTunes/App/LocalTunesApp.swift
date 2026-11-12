import SwiftUI

@main
struct LocalTunesApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack {
                    ContentUnavailableView("Your music. Your space.", systemImage: "waveform", description: Text("Welcome to LocalTunes. Your offline music library lives on this iPhone."))
                        .navigationTitle("Listen")
                }.tabItem { Label("Home", systemImage: "house.fill") }
                NavigationStack {
                    ContentUnavailableView("Your library starts here", systemImage: "music.note.list", description: Text("Import music from Files to begin."))
                        .navigationTitle("Library")
                }.tabItem { Label("Library", systemImage: "square.stack.fill") }
                NavigationStack { Text("Search your local library").navigationTitle("Search") }
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                NavigationStack { Text("Your personal playlists").navigationTitle("Playlists") }
                    .tabItem { Label("Playlists", systemImage: "music.note.list") }
                NavigationStack { Text("Entirely offline. Entirely yours.").navigationTitle("Settings") }
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            }.tint(.accentColor).preferredColorScheme(.dark)
        }
    }
}
