import Foundation

/// Reads/writes the diarization turns sidecar consumed by the Python worker.
/// The sidecar is named after the audio file that was diarized, matching the
/// worker's `splitext(path)[0] + "_diarization.json"` rule.
enum DiarizationSidecar {
    private struct Payload: Codable {
        let turns: [DiarizationTurn]
    }

    /// Sidecar path for a given diarized audio file.
    static func sidecarPath(forAudioAt audioPath: URL) -> URL {
        let dir = audioPath.deletingLastPathComponent()
        let stem = audioPath.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(stem)_diarization.json")
    }

    /// Atomically writes `{"turns":[…]}` next to the diarized audio file.
    static func write(_ turns: [DiarizationTurn], forAudioAt audioPath: URL) throws {
        let url = sidecarPath(forAudioAt: audioPath)
        let data = try JSONEncoder().encode(Payload(turns: turns))
        try data.write(to: url, options: .atomic) // temp file + rename under the hood
    }
}
