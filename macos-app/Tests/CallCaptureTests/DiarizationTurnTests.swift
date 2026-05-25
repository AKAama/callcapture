import Testing
import Foundation
@testable import CallCapture

@Suite("DiarizationTurn")
struct DiarizationTurnTests {
    @Test @available(macOS 14.2, *)
    func encodesExactlyTheWorkerContractKeys() throws {
        let turn = DiarizationTurn(speaker: "Speaker 1", start: 0.0, end: 2.5)
        let data = try JSONEncoder().encode(turn)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["speaker"] as? String == "Speaker 1")
        #expect(obj["start"] as? Double == 0.0)
        #expect(obj["end"] as? Double == 2.5)
        #expect(obj.keys.count == 3) // no extra / snake_cased keys
    }
}
