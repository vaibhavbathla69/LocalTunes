import Foundation
import AVFoundation
import Accelerate

actor AudioAnalysisService {
    static let shared = AudioAnalysisService()
    func measure(_ url: URL) async throws -> LoudnessMeasurement {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384) else {
            throw LibraryError.message("Cannot allocate audio analysis buffer.")
        }
        var sum = 0.0, samples = 0.0, peak: Float = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                var rms: Float = 0, maximum: Float = 0
                vDSP_rmsqv(channels[channel], 1, &rms, vDSP_Length(buffer.frameLength))
                vDSP_maxmgv(channels[channel], 1, &maximum, vDSP_Length(buffer.frameLength))
                sum += Double(rms) * Double(rms) * Double(buffer.frameLength)
                samples += Double(buffer.frameLength); peak = max(peak, maximum)
            }
            await Task.yield()
        }
        return LoudnessMeasurement(rms: samples > 0 ? sqrt(sum / samples) : 0, peak: Double(peak))
    }
}
