import Testing
@testable import CallCapture

@Suite("System/mic buffer split")
struct BufferSplitTests {
    @available(macOS 14.2, *)
    @Test("mic 1ch + tap 2ch as two buffers")
    func micThenTap() {
        // buffers: [mic 1ch, tap 2ch], system=2 -> system starts at index 1
        #expect(AudioCaptureManager.systemBufferSplit(channelCounts: [1, 2], systemChannels: 2) == 1)
    }

    @available(macOS 14.2, *)
    @Test("per-channel layout: 1ch mic + 2x1ch tap")
    func perChannel() {
        // buffers: [1,1,1], system=2 -> trailing two buffers sum to 2 -> index 1
        #expect(AudioCaptureManager.systemBufferSplit(channelCounts: [1, 1, 1], systemChannels: 2) == 1)
    }

    @available(macOS 14.2, *)
    @Test("no mic: all buffers are system")
    func noMic() {
        #expect(AudioCaptureManager.systemBufferSplit(channelCounts: [2], systemChannels: 2) == 0)
    }

    @available(macOS 14.2, *)
    @Test("stereo mic + stereo tap")
    func stereoBoth() {
        #expect(AudioCaptureManager.systemBufferSplit(channelCounts: [2, 2], systemChannels: 2) == 1)
    }

    @available(macOS 14.2, *)
    @Test("returns nil when trailing channels cannot sum to systemChannels")
    func unsplittable() {
        // trailing sums: 2, then 2+1=3 — never exactly 3 from a clean buffer boundary for system=3
        #expect(AudioCaptureManager.systemBufferSplit(channelCounts: [1, 2], systemChannels: 3) == 0)
    }
}
