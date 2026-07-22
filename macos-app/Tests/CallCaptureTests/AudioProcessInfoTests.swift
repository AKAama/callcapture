import CoreAudio
import Testing
@testable import CallCapture

@Suite("AudioProcessInfo")
struct AudioProcessInfoTests {
    @Test("normalization filters invalid, current, and duplicate processes before sorting by name")
    func normalizeProcesses() {
        let candidates = [
            AudioProcessInfo(id: 10, pid: 410, name: "Zoom", bundleID: "us.zoom.xos"),
            AudioProcessInfo(id: 11, pid: 0, name: "Invalid Zero", bundleID: nil),
            AudioProcessInfo(id: 12, pid: -1, name: "Invalid Negative", bundleID: nil),
            AudioProcessInfo(id: 13, pid: 900, name: "CallCapture", bundleID: "com.callcapture.app"),
            AudioProcessInfo(id: 14, pid: 410, name: "Duplicate Zoom", bundleID: nil),
            AudioProcessInfo(id: 15, pid: 220, name: "Feishu", bundleID: "com.bytedance.Feishu"),
        ]

        let normalized = AudioProcessEnumerator.normalize(candidates, currentPID: 900)

        #expect(normalized.map(\.pid) == [220, 410])
        #expect(normalized.map(\.name) == ["Feishu", "Zoom"])
        #expect(normalized.map(\.id) == [15, 10])
    }
}
