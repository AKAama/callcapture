import Foundation

/// Transcription engine selection: local Whisper or a remote API provider.
enum TranscriptionEngine: String, Codable, CaseIterable, Sendable {
    case localWhisper = "local_whisper"
    case remote

    var displayName: String {
        switch self {
        case .localWhisper: "Local Whisper"
        case .remote: "Remote API"
        }
    }
}

/// Whisper model size for local transcription.
enum WhisperModel: String, Codable, CaseIterable, Sendable {
    case base
    case small
    case medium

    var displayName: String {
        switch self {
        case .base: "Base (fastest)"
        case .small: "Small (balanced)"
        case .medium: "Medium (accurate)"
        }
    }
}

/// Remote transcription provider when using a cloud API.
enum RemoteProvider: String, Codable, CaseIterable, Sendable {
    case groq
    case openai
    case deepgram

    var displayName: String {
        switch self {
        case .groq: "Groq"
        case .openai: "OpenAI"
        case .deepgram: "Deepgram"
        }
    }
}

/// LLM engine for post-processing transcripts.
enum LLMEngine: String, Codable, CaseIterable, Sendable {
    case claude
    case openai
    case localExperimental = "local_experimental"

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .openai: "OpenAI"
        case .localExperimental: "Local (Experimental)"
        }
    }
}

/// Where LLM post-processing runs.
enum LLMProvider: String, Codable, CaseIterable, Sendable {
    case openrouter
    case local

    var displayName: String {
        switch self {
        case .openrouter: "OpenRouter (cloud)"
        case .local: "Local (Ollama)"
        }
    }
}

/// Markdown output profile for transcript formatting.
enum MarkdownProfile: String, Codable, CaseIterable, Sendable {
    case meetingNotes = "meeting_notes"
    case fullTranscript = "full_transcript"
    case obsidian

    var displayName: String {
        switch self {
        case .meetingNotes: "Meeting Notes"
        case .fullTranscript: "Full Transcript"
        case .obsidian: "Obsidian"
        }
    }
}
