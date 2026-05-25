import Foundation

/// A single speaker turn over the remote-audio timeline. Encodes to the Python
/// worker's diarization-sidecar contract: `{"speaker","start","end"}`.
struct DiarizationTurn: Codable, Equatable, Sendable {
    let speaker: String
    let start: Double
    let end: Double
}

/// A swappable speaker-diarization engine. FluidAudio is the default provider;
/// pyannote is the documented fallback. Implementations own their model lifecycle.
protocol DiarizationProvider: Sendable {
    /// Downloads (if needed) and loads diarization models. Called from the
    /// Settings download action; safe to call repeatedly.
    func prepareModels() async throws

    /// Diarizes the audio at `audioPath` into normalized speaker turns
    /// ("Speaker 1", "Speaker 2", … by order of first appearance).
    func diarize(audioPath: URL) async throws -> [DiarizationTurn]
}
