import Foundation
import GRDB

/// GRDB record mapping to the `session` table.
///
/// Provides bidirectional conversion between the persistence layer
/// and the domain `Session` model used throughout the app.
struct SessionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {

    static let databaseTableName = "session"

    let id: String
    let title: String
    let sourceApp: String
    let captureMode: String
    let startedAt: String
    var endedAt: String?
    var durationSec: Double?
    let audioPath: String
    var recordingType: String
    var language: String
    var notesLanguage: String
    var analysisPath: String?
    var transcriptRawPath: String?
    var transcriptMarkdownPath: String?
    var engineUsed: String?
    var status: String
    var errorMessage: String?
    var costTranscription: Double?
    var costProcessing: Double?
    var costCurrency: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case sourceApp = "source_app"
        case captureMode = "capture_mode"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSec = "duration_sec"
        case audioPath = "audio_path"
        case recordingType = "recording_type"
        case language
        case notesLanguage = "notes_language"
        case analysisPath = "analysis_path"
        case transcriptRawPath = "transcript_raw_path"
        case transcriptMarkdownPath = "transcript_markdown_path"
        case engineUsed = "engine_used"
        case status
        case errorMessage = "error_message"
        case costTranscription = "cost_transcription"
        case costProcessing = "cost_processing"
        case costCurrency = "cost_currency"
    }

    /// Returns sessions ordered newest-first by `started_at`.
    static func orderedByDate() -> QueryInterfaceRequest<SessionRecord> {
        SessionRecord.order(Column("started_at").desc)
    }
}

// MARK: - Domain Conversion

extension SessionRecord {

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Converts this record to the domain `Session` model.
    func toSession() -> Session {
        let formatter = SessionRecord.iso8601Formatter
        let started = formatter.date(from: startedAt) ?? Date.distantPast
        let ended = endedAt.flatMap { formatter.date(from: $0) }

        return Session(
            id: id,
            title: title,
            sourceApp: sourceApp,
            startedAt: started,
            endedAt: ended,
            durationSec: durationSec,
            audioPath: audioPath,
            transcriptRawPath: transcriptRawPath,
            transcriptMarkdownPath: transcriptMarkdownPath,
            recordingType: recordingType,
            language: language,
            notesLanguage: notesLanguage,
            analysisPath: analysisPath,
            costTranscription: costTranscription,
            costProcessing: costProcessing,
            costCurrency: costCurrency,
            status: status
        )
    }

    /// Creates a record from the domain `Session` model.
    init(from session: Session) {
        let formatter = SessionRecord.iso8601Formatter
        self.id = session.id
        self.title = session.title
        self.sourceApp = session.sourceApp
        self.captureMode = "default_output"
        self.startedAt = formatter.string(from: session.startedAt)
        self.endedAt = session.endedAt.map { formatter.string(from: $0) }
        self.durationSec = session.durationSec
        self.audioPath = session.audioPath
        self.recordingType = session.recordingType
        self.language = session.language
        self.notesLanguage = session.notesLanguage
        self.analysisPath = session.analysisPath
        self.transcriptRawPath = session.transcriptRawPath
        self.transcriptMarkdownPath = session.transcriptMarkdownPath
        self.engineUsed = nil
        self.status = session.status
        self.errorMessage = nil
        self.costTranscription = session.costTranscription
        self.costProcessing = session.costProcessing
        self.costCurrency = session.costCurrency
    }
}
