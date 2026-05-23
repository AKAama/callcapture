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
    var transcriptRawPath: String?
    var transcriptMarkdownPath: String?
    var engineUsed: String?
    var status: String
    var errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case sourceApp = "source_app"
        case captureMode = "capture_mode"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSec = "duration_sec"
        case audioPath = "audio_path"
        case transcriptRawPath = "transcript_raw_path"
        case transcriptMarkdownPath = "transcript_markdown_path"
        case engineUsed = "engine_used"
        case status
        case errorMessage = "error_message"
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
        self.transcriptRawPath = session.transcriptRawPath
        self.transcriptMarkdownPath = session.transcriptMarkdownPath
        self.engineUsed = nil
        self.status = session.status
        self.errorMessage = nil
    }
}
