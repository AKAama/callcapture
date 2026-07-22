import Foundation

/// Errors that can occur during audio capture operations.
enum CaptureError: LocalizedError {
    case tapCreationFailed(status: OSStatus)
    case noDefaultOutputDevice
    case deviceNotProducingAudio
    case fileWriterInitFailed(underlying: Error)
    case alreadyRecording
    case notRecording
    case ioProcCleanupFailed(stopStatus: OSStatus, destroyStatus: OSStatus)
    case finalizationFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let status):
            "Failed to create audio tap (OSStatus: \(status)). "
            + "Check System Audio Recording permission in System Settings > Privacy & Security."
        case .noDefaultOutputDevice:
            "No default audio output device found."
        case .deviceNotProducingAudio:
            "Target audio device is not producing audio. "
            + "Start playing audio before recording."
        case .fileWriterInitFailed(let error):
            "Failed to initialize audio file writer: \(error.localizedDescription)"
        case .alreadyRecording:
            "A recording is already in progress."
        case .notRecording:
            "No recording is in progress."
        case .ioProcCleanupFailed(let stopStatus, let destroyStatus):
            "Failed to release the audio IO callback "
            + "(stop OSStatus: \(stopStatus), destroy OSStatus: \(destroyStatus)). "
            + "Capture resources were retained so cleanup can be retried."
        case .finalizationFailed(let error):
            "Failed to finalize audio file: \(error.localizedDescription)"
        }
    }
}
