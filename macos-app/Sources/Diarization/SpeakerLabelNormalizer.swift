import Foundation

/// A diarization turn as emitted by an engine, keyed by an opaque cluster id.
/// Engines use Int or String ids; both are carried here as `String`.
struct RawSpeakerTurn: Equatable, Sendable {
    let clusterId: String
    let start: Double
    let end: Double
}

/// Maps opaque cluster ids to "Speaker 1", "Speaker 2", … by order of first
/// appearance, preserving turn order and timings.
func normalizeTurns(_ raw: [RawSpeakerTurn]) -> [DiarizationTurn] {
    var labelForCluster: [String: String] = [:]
    var nextIndex = 1
    var result: [DiarizationTurn] = []
    for turn in raw {
        let label: String
        if let existing = labelForCluster[turn.clusterId] {
            label = existing
        } else {
            label = "Speaker \(nextIndex)"
            labelForCluster[turn.clusterId] = label
            nextIndex += 1
        }
        result.append(DiarizationTurn(speaker: label, start: turn.start, end: turn.end))
    }
    return result
}
