import SwiftUI

struct WiFiTransferView: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.scenePhase) private var phase
    @StateObject private var service = WiFiTransferService()
    @State private var clearing = false
    var body: some View {
        List {
            Section("PC to iPhone") {
                Text("Connect both devices to the same local network. Open the address below in your PC browser, then choose files or a folder.")
                if let address = service.address {
                    Text(address).font(.body.monospaced()).textSelection(.enabled)
                    Button("Copy transfer address", systemImage: "doc.on.doc") { UIPasteboard.general.string = address }
                }
                Text(service.message).font(.subheadline).foregroundStyle(.secondary)
                if service.running { Button("Stop transfer", role: .destructive) { service.stop() } }
                else { Button("Start Wi-Fi transfer", systemImage: "wifi") { Task { await service.start(library.paths) } }.disabled(library.isImporting || library.storageCleanupActive) }
            }
            Section("Received files") {
                LabeledContent("Ready to import", value: String(service.received.count))
                Button("Import received files", systemImage: "square.and.arrow.down") { library.importURLs(service.received) }
                    .disabled(service.running || service.received.isEmpty || library.isImporting || library.storageCleanupActive)
                Text("Stop transfer before importing. Interrupted uploads stay on this phone; select the same files in the browser to resume. Original received files can be removed later using Storage cleanup.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text("Keep this screen open. Transfer stops when the app goes into the background. This is local HTTP transfer: use a trusted network, and share the address only with your own devices.").font(.footnote).foregroundStyle(.secondary)
                Button("Clear partial uploads", role: .destructive) { clearing = true }.disabled(service.running)
            }
        }.navigationTitle("Wi-Fi transfer")
            .task { await service.prepare(library.paths) }
            .onDisappear { service.stop() }
            .onChange(of: phase) { _, value in if value == .background { service.stop() } }
            .confirmationDialog("Remove incomplete uploads?", isPresented: $clearing, titleVisibility: .visible) {
                Button("Clear partial uploads", role: .destructive) { Task { await service.clearPartials() } }
            } message: { Text("Completed transfers and library music are kept.") }
    }
}
