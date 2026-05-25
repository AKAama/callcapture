import Foundation

/// Request sent to the Python worker via stdin as JSON.
/// Matches the Python worker's expected input schema exactly.
struct JobRequest: Codable, Sendable {
    let jobId: String
    let command: String
    let audioPath: String
    let engine: String
    let language: String
    let speakerDiarization: Bool
    let markdownProfile: String
    let whisperModel: String
    let llmEngine: String
    let remoteProvider: String
    let recordingType: String

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case command
        case audioPath = "audio_path"
        case engine
        case language
        case speakerDiarization = "speaker_diarization"
        case markdownProfile = "markdown_profile"
        case whisperModel = "whisper_model"
        case llmEngine = "llm_engine"
        case remoteProvider = "remote_provider"
        case recordingType = "recording_type"
    }

    /// Creates a default transcription request for a given audio file.
    static func transcribe(
        audioPath: String,
        engine: String = "local_whisper",
        whisperModel: String = "base",
        llmEngine: String = "claude",
        remoteProvider: String = "groq"
    ) -> JobRequest {
        JobRequest(
            jobId: UUID().uuidString,
            command: "transcribe",
            audioPath: audioPath,
            engine: engine,
            language: "auto",
            speakerDiarization: false,
            markdownProfile: "meeting_notes",
            whisperModel: whisperModel,
            llmEngine: llmEngine,
            remoteProvider: remoteProvider,
            recordingType: "call_meeting"
        )
    }

    /// Creates a request that asks the worker to download the acoustic-emotion model.
    static func prepareEmotion() -> JobRequest {
        JobRequest(
            jobId: UUID().uuidString,
            command: "prepare_emotion",
            audioPath: "",
            engine: "local_whisper",
            language: "auto",
            speakerDiarization: false,
            markdownProfile: "meeting_notes",
            whisperModel: "base",
            llmEngine: "claude",
            remoteProvider: "groq",
            recordingType: "call_meeting"
        )
    }

    /// Creates a transcription request configured from a session and settings.
    ///
    /// - Parameters:
    ///   - session: The recording session to transcribe.
    ///   - settings: The settings manager providing engine configuration.
    static func transcribe(
        session: Session,
        settings: SettingsManager
    ) -> JobRequest {
        JobRequest(
            jobId: session.id,
            command: "transcribe",
            audioPath: session.audioPath,
            engine: settings.defaultEngine.rawValue,
            language: "auto",
            speakerDiarization: settings.enableDiarization,
            markdownProfile: settings.markdownProfile.rawValue,
            whisperModel: settings.whisperModel.rawValue,
            llmEngine: settings.llmEngine.rawValue,
            remoteProvider: settings.remoteProvider.rawValue,
            recordingType: session.recordingType
        )
    }
}

/// Progress update streamed by the Python worker on stderr.
struct ProgressUpdate: Codable, Sendable {
    let jobId: String
    let progress: Double
    let stage: String
    let currentSegment: Int?

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case progress
        case stage
        case currentSegment = "current_segment"
    }
}

/// Final result returned by the Python worker on stdout.
struct JobResult: Codable, Sendable {
    let jobId: String
    let status: String
    let rawTranscriptPath: String?
    let markdownPath: String?
    let analysisPath: String?
    let durationSec: Double?
    let warnings: [String]
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case status
        case rawTranscriptPath = "raw_transcript_path"
        case markdownPath = "markdown_path"
        case analysisPath = "analysis_path"
        case durationSec = "duration_sec"
        case warnings
        case errorMessage = "error_message"
    }

    /// Creates an error result when the worker process fails.
    static func error(jobId: String, message: String) -> JobResult {
        JobResult(
            jobId: jobId,
            status: "error",
            rawTranscriptPath: nil,
            markdownPath: nil,
            analysisPath: nil,
            durationSec: nil,
            warnings: [message],
            errorMessage: message
        )
    }
}

/// Heartbeat ping sent to keep long-running jobs alive.
struct HeartbeatPing: Codable, Sendable {
    let action: String = "ping"
}

/// Heartbeat pong expected from the worker on stderr.
struct HeartbeatPong: Codable, Sendable {
    let pong: Bool
}
