import SwiftUI
import AVFoundation

struct AudioDetailsView: View {
    @EnvironmentObject private var library: LibraryModel
    let song: Song
    @State private var rate: Double?
    @State private var bits: Int?
    @State private var channels: Int?
    @State private var error: String?
    var body: some View {
        List {
            Section("Source file") {
                LabeledContent("Format", value: (song.relativePath as NSString).pathExtension.uppercased())
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: song.byteCount, countStyle: .file))
                LabeledContent("Average file bitrate", value: "\(Int(Double(song.byteCount) * 8 / max(1, song.duration) / 1000)) kbps")
                if let rate { LabeledContent("Sample rate", value: String(format: "%.1f kHz", rate / 1000)) }
                if let bits {
                    LabeledContent("Bit depth", value: "\(bits)-bit")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Bit depth")
                        .accessibilityValue("\(bits)-bit")
                        .accessibilityIdentifier("audio.bitDepth")
                }
                if let channels { LabeledContent("Channels", value: String(channels)) }
                if let error { Text(error).foregroundStyle(.secondary) }
            }
            Section("Playback output") {
                LabeledContent("Device sample rate", value: String(format: "%.1f kHz", AVAudioSession.sharedInstance().sampleRate / 1000))
                Text("Source properties do not guarantee lossless output. Bluetooth, the selected route and system processing can change the output format.").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Audio details").task {
            let url = library.paths.audioURL(for: song)
            do {
                let info = try await Task.detached { () -> (Double, Int?, Int) in
                    if url.pathExtension.lowercased() == "flac" {
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        guard let data = try handle.read(upToCount: 42), data.count == 42,
                              data.prefix(4) == Data("fLaC".utf8), data[4] & 127 == 0 else { throw LibraryError.message("Invalid FLAC header") }
                        let packed = data[18..<26].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                        return (Double(packed >> 44), Int((packed >> 36) & 31) + 1, Int((packed >> 41) & 7) + 1)
                    }
                    let file = try AVAudioFile(forReading: url)
                    let asbd = file.fileFormat.streamDescription.pointee
                    return (file.fileFormat.sampleRate, asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil, Int(file.fileFormat.channelCount))
                }.value
                rate = info.0; bits = info.1; channels = info.2
            } catch { self.error = error.localizedDescription }
        }
    }
}
