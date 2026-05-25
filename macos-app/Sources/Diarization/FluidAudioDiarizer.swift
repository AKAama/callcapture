import Foundation
import FluidAudio
import OSLog

/// FluidAudio-backed diarizer: runs the offline CoreML diarization pipeline on
/// the Apple Neural Engine and maps results to normalized speaker turns. An actor
/// so its lazily-loaded model state is safely shared across calls. The only type
/// that imports FluidAudio — swap by providing another DiarizationProvider.
actor FluidAudioDiarizer: DiarizationProvider {
    private var manager: OfflineDiarizerManager?
    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "FluidAudioDiarizer"
    )

    func prepareModels() async throws {
        _ = try await loadedManager()
    }

    func diarize(audioPath: URL) async throws -> [DiarizationTurn] {
        let mgr = try await loadedManager()
        let result = try await mgr.process(audioPath)
        let raw = result.segments.map { segment in
            RawSpeakerTurn(
                clusterId: segment.speakerId,
                start: Double(segment.startTimeSeconds),
                end: Double(segment.endTimeSeconds)
            )
        }
        Self.logger.debug("Diarized \(raw.count) segments from \(audioPath.lastPathComponent)")
        return normalizeTurns(raw)
    }

    /// Creates and prepares the manager once per process. `prepareModels()` loads
    /// models from the local cache, downloading only if absent.
    private func loadedManager() async throws -> OfflineDiarizerManager {
        if let manager { return manager }
        let created = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await created.prepareModels()
        manager = created
        Self.logger.info("FluidAudio diarizer models loaded")
        return created
    }
}
