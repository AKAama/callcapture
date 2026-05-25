import Foundation
import OSLog

/// Orchestrates speaker diarization for a session: decides whether to run,
/// picks the remote-audio file, invokes the provider, and writes the turns
/// sidecar the Python worker reads. Any failure is logged and swallowed so
/// transcription is never blocked.
final class DiarizationService {
    private let provider: any DiarizationProvider
    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "Diarization"
    )

    init(provider: any DiarizationProvider) {
        self.provider = provider
    }

    /// Downloads/loads diarization models. Surfaced to the Settings download UI.
    func prepareModels() async throws {
        try await provider.prepareModels()
    }

    /// Diarizes the session's remote audio and writes the sidecar, if the
    /// recording type diarizes and models are ready. No-op / graceful-degrade
    /// otherwise.
    func diarizeIfNeeded(session: Session, modelsReady: Bool) async {
        guard let type = RecordingType(rawValue: session.recordingType), type.diarize else {
            return
        }
        guard modelsReady else {
            Self.logger.info("Diarization skipped for \(session.id): models not downloaded")
            return
        }

        let remoteURL = Self.remoteAudioURL(for: session)
        do {
            let turns = try await provider.diarize(audioPath: remoteURL)
            try DiarizationSidecar.write(turns, forAudioAt: remoteURL)
            Self.logger.info("Diarization wrote \(turns.count) turns for \(session.id)")
        } catch {
            Self.logger.error("Diarization failed for \(session.id): \(error)")
        }
    }

    /// The remote-audio file to diarize: the system stem when it exists (a mic
    /// was selected), otherwise the mixed/single recording (output-only = remote).
    static func remoteAudioURL(for session: Session) -> URL {
        let audio = URL(fileURLWithPath: session.audioPath)
        let dir = audio.deletingLastPathComponent()
        let stem = audio.deletingPathExtension().lastPathComponent
        let systemURL = dir.appendingPathComponent("\(stem)_system.wav")
        return FileManager.default.fileExists(atPath: systemURL.path) ? systemURL : audio
    }
}
