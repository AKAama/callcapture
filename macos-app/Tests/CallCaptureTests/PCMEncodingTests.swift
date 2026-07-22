import AVFoundation
import Testing
@testable import CallCapture

@Suite("PCM encoding")
struct PCMEncodingTests {
    @available(macOS 14.2, *)
    @Test("Float32 samples saturate when encoded as little-endian PCM16")
    func saturatingPCM16Encoding() throws {
        let samples: [Float] = [-1.5, -1, 0, 0.5, 1, 1.5]
        let format = try #require(
            AVAudioFormat(
                standardFormatWithSampleRate: 16_000,
                channels: 1
            )
        )
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        )
        let channel = try #require(buffer.floatChannelData?[0])
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }

        let data = AudioCaptureManager.pcm16Data(from: buffer)
        let encoded = stride(from: 0, to: data.count, by: 2).map { offset in
            let bits = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            return Int16(bitPattern: bits)
        }

        #expect(encoded == [-32768, -32768, 0, 16384, 32767, 32767])
    }
}
