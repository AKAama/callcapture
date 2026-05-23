import Foundation
import GRDB

/// GRDB record mapping to the `job` table.
///
/// Tracks transcription and processing jobs associated with a session.
struct JobRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {

    static let databaseTableName = "job"

    let id: String
    let sessionId: String
    let type: String
    var status: String
    let startedAt: String
    var endedAt: String?
    var attemptCount: Int
    var warningsJson: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case type
        case status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case attemptCount = "attempt_count"
        case warningsJson = "warnings_json"
    }

    /// Returns jobs for a given session, newest-first.
    static func forSession(id: String) -> QueryInterfaceRequest<JobRecord> {
        JobRecord
            .filter(Column("session_id") == id)
            .order(Column("started_at").desc)
    }
}
