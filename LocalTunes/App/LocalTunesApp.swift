import SwiftUI

@main
struct LocalTunesApp: App {
    var body: some Scene {
        WindowGroup { BootstrapView().preferredColorScheme(.dark).tint(Palette.accent) }
    }
}

private struct BootstrapView: View {
    @State private var library: LibraryModel?
    @State private var error: String?
    var body: some View {
        Group {
            if let library {
                RootView().environmentObject(library).environmentObject(library.player)
            } else if let error {
                ContentUnavailableView {
                    Label("Your library is protected", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(error + "\n\nNo library was reset. Close and reopen the app, or back up its Documents folder before troubleshooting.")
                }
            } else { ProgressView("Opening your collection…") }
        }.background(Palette.background)
            .task {
                guard library == nil, error == nil else { return }
                do {
                    let paths: LibraryPaths
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-test-isolated-library") {
                        paths = try LibraryPaths(documents: FileManager.default.temporaryDirectory.appendingPathComponent("UITest-" + UUID().uuidString))
                    } else { paths = try LibraryPaths() }
                    #else
                    paths = try LibraryPaths()
                    #endif
                    let db = try LibraryDatabase(url: paths.database)
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-test-isolated-library"), ProcessInfo.processInfo.arguments.contains("--ui-test-seed-audio") {
                        try await UITestSupport.seed(paths: paths, db: db)
                    }
                    #endif
                    let model = LibraryModel(paths: paths, db: db)
                    await model.load()
                    library = model
                } catch { self.error = error.localizedDescription }
            }
    }
}
