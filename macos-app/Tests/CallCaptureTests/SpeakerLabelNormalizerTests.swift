import Testing
@testable import CallCapture

@Suite("SpeakerLabelNormalizer")
struct SpeakerLabelNormalizerTests {
    @Test @available(macOS 14.2, *)
    func mapsClusterIdsByFirstAppearance() {
        let raw = [
            RawSpeakerTurn(clusterId: "7", start: 0.0, end: 1.0),
            RawSpeakerTurn(clusterId: "3", start: 1.0, end: 2.0),
            RawSpeakerTurn(clusterId: "7", start: 2.0, end: 3.0),
            RawSpeakerTurn(clusterId: "3", start: 3.0, end: 4.0),
        ]
        let turns = normalizeTurns(raw)
        #expect(turns.map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 1", "Speaker 2"])
        #expect(turns.map(\.start) == [0.0, 1.0, 2.0, 3.0])
        #expect(turns.map(\.end) == [1.0, 2.0, 3.0, 4.0])
    }

    @Test @available(macOS 14.2, *)
    func emptyInputProducesEmptyOutput() {
        #expect(normalizeTurns([]).isEmpty)
    }

    @Test @available(macOS 14.2, *)
    func singleSpeakerIsSpeakerOne() {
        let raw = [RawSpeakerTurn(clusterId: "x", start: 0, end: 5)]
        #expect(normalizeTurns(raw).map(\.speaker) == ["Speaker 1"])
    }
}
