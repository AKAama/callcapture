import Testing
import Foundation
@testable import CallCapture

@Suite("DiarizationSidecar")
struct DiarizationSidecarTests {
    @Test @available(macOS 14.2, *)
    func sidecarPathForMixedFile() {
        let audio = URL(fileURLWithPath: "/tmp/x/abc.wav")
        let side = DiarizationSidecar.sidecarPath(forAudioAt: audio)
        #expect(side.lastPathComponent == "abc_diarization.json")
        #expect(side.deletingLastPathComponent().path == "/tmp/x")
    }

    @Test @available(macOS 14.2, *)
    func sidecarPathForSystemStem() {
        let audio = URL(fileURLWithPath: "/tmp/x/abc_system.wav")
        #expect(DiarizationSidecar.sidecarPath(forAudioAt: audio).lastPathComponent
                == "abc_system_diarization.json")
    }

    @Test @available(macOS 14.2, *)
    func writeProducesWorkerCompatibleJSON() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let audio = dir.appendingPathComponent("abc_system.wav")
        let turns = [
            DiarizationTurn(speaker: "Speaker 1", start: 0.0, end: 2.5),
            DiarizationTurn(speaker: "Speaker 2", start: 2.5, end: 5.0),
        ]
        try DiarizationSidecar.write(turns, forAudioAt: audio)

        let side = dir.appendingPathComponent("abc_system_diarization.json")
        #expect(FileManager.default.fileExists(atPath: side.path))
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: side)) as? [String: Any]
        )
        let arr = try #require(obj["turns"] as? [[String: Any]])
        #expect(arr.count == 2)
        #expect(arr[0]["speaker"] as? String == "Speaker 1")
        #expect(arr[0]["start"] as? Double == 0.0)
        #expect(arr[1]["end"] as? Double == 5.0)
    }
}
