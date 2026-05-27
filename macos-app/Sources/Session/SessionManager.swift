import Foundation
import GRDB
import OSLog

/// Represents a single recording session with metadata.
struct Session: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let sourceApp: String
    let startedAt: Date
    var endedAt: Date?
    var durationSec: Double?
    var audioPath: String
    var transcriptRawPath: String? = nil
    var transcriptMarkdownPath: String? = nil
    var recordingType: String = "call_meeting"
    var analysisPath: String? = nil
    var status: String

    /// URL for the session's audio file.
    var audioFileURL: URL {
        URL(fileURLWithPath: audioPath)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case sourceApp = "source_app"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSec = "duration_sec"
        case audioPath = "audio_path"
        case transcriptRawPath = "transcript_raw_path"
        case transcriptMarkdownPath = "transcript_markdown_path"
        case recordingType = "recording_type"
        case analysisPath = "analysis_path"
        case status
    }
}

/// Manages recording session lifecycle and persistence via GRDB.
@Observable
final class SessionManager {

    private(set) var currentSession: Session?
    private(set) var recentSessions: [Session] = []

    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "SessionManager"
    )

    private let database: AppDatabase
    private let storageDirectory: URL

    /// Creates a session manager backed by the given database.
    ///
    /// - Parameter database: The GRDB-backed application database.
    init(database: AppDatabase) {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        self.storageDirectory = appSupport
            .appendingPathComponent("CallCapture", isDirectory: true)
        self.database = database

        createDirectoriesIfNeeded()
        reconcileInterruptedSessions()
        loadRecentSessions()
    }

    /// Marks any session left in `recording` state as `interrupted`.
    ///
    /// A session stuck in `recording` means a previous run was killed
    /// mid-capture (crash, force quit, power loss) before `finalizeSession`
    /// ran. Without this, such sessions render as perpetually recording.
    /// Called once at launch.
    private func reconcileInterruptedSessions() {
        do {
            let count = try database.dbPool.write { db in
                try SessionRecord
                    .filter(Column("status") == "recording")
                    .updateAll(db, Column("status").set(to: "interrupted"))
            }
            if count > 0 {
                Self.logger.warning(
                    "Reconciled \(count) interrupted session(s) left in 'recording' state"
                )
            }
        } catch {
            Self.logger.error("Failed to reconcile interrupted sessions: \(error)")
        }
    }

    /// Creates a new session with a generated title and audio file path.
    ///
    /// - Parameter sourceApp: Name of the application being recorded.
    /// - Returns: The newly created session.
    @discardableResult
    func createSession(
        sourceApp: String,
        recordingType: RecordingType = .callMeeting
    ) -> Session {
        let sessionId = UUID().uuidString
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let title = "\(sourceApp) - \(formatter.string(from: now))"

        let audioDir = storageDirectory
            .appendingPathComponent("audio", isDirectory: true)
        let audioPath = audioDir
            .appendingPathComponent("\(sessionId).wav")

        let session = Session(
            id: sessionId,
            title: title,
            sourceApp: sourceApp,
            startedAt: now,
            audioPath: audioPath.path,
            recordingType: recordingType.rawValue,
            status: "recording"
        )

        let record = SessionRecord(from: session)
        do {
            try database.dbPool.write { db in
                try record.insert(db)
            }
        } catch {
            Self.logger.error("Failed to insert session: \(error)")
        }

        currentSession = session
        Self.logger.info("Session created: \(sessionId) - \(title)")
        return session
    }

    /// Marks the current session as completed and persists the update.
    func finalizeSession() {
        guard let session = currentSession else {
            Self.logger.warning("No active session to finalize")
            return
        }

        let now = Date()
        let finalized = Session(
            id: session.id,
            title: session.title,
            sourceApp: session.sourceApp,
            startedAt: session.startedAt,
            endedAt: now,
            durationSec: now.timeIntervalSince(session.startedAt),
            audioPath: session.audioPath,
            recordingType: session.recordingType,
            analysisPath: session.analysisPath,
            status: "completed"
        )

        do {
            try database.dbPool.write { db in
                let record = SessionRecord(from: finalized)
                try record.update(db)
            }
        } catch {
            Self.logger.error("Failed to finalize session: \(error)")
        }

        recentSessions.insert(finalized, at: 0)
        if recentSessions.count > 50 {
            recentSessions = Array(recentSessions.prefix(50))
        }
        currentSession = nil

        Self.logger.info(
            "Session finalized: \(finalized.id), duration=\(finalized.durationSec ?? 0)s"
        )
    }

    /// Returns all sessions ordered by date, newest first.
    func allSessions() -> [Session] {
        do {
            return try database.dbPool.read { db in
                let records = try SessionRecord.orderedByDate().fetchAll(db)
                return records.map { $0.toSession() }
            }
        } catch {
            Self.logger.error("Failed to load all sessions: \(error)")
            return []
        }
    }

    /// Returns a single session by its identifier.
    ///
    /// - Parameter id: The session identifier.
    /// - Returns: The session, or `nil` if not found.
    func session(id: String) -> Session? {
        do {
            return try database.dbPool.read { db in
                let record = try SessionRecord.fetchOne(db, key: id)
                return record?.toSession()
            }
        } catch {
            Self.logger.error("Failed to fetch session \(id): \(error)")
            return nil
        }
    }

    /// Updates transcript paths and engine after transcription completes.
    ///
    /// - Parameters:
    ///   - id: Session identifier.
    ///   - rawTranscriptPath: Path to the raw transcript file.
    ///   - markdownPath: Path to the Markdown transcript file.
    ///   - engineUsed: Transcription engine name.
    func updateSessionPaths(
        id: String,
        rawTranscriptPath: String?,
        markdownPath: String?,
        engineUsed: String?
    ) {
        do {
            try database.dbPool.write { db in
                guard var record = try SessionRecord.fetchOne(db, key: id) else {
                    Self.logger.warning("Session not found for path update: \(id)")
                    return
                }
                record.transcriptRawPath = rawTranscriptPath
                record.transcriptMarkdownPath = markdownPath
                record.engineUsed = engineUsed
                try record.update(db)
            }
        } catch {
            Self.logger.error("Failed to update session paths for \(id): \(error)")
        }
    }

    /// Persists the analysis JSON path for a session.
    ///
    /// - Parameters:
    ///   - id: Session identifier.
    ///   - analysisPath: Path to the conversation analysis JSON file.
    func updateAnalysisPath(id: String, analysisPath: String?) {
        do {
            try database.dbPool.write { db in
                guard var record = try SessionRecord.fetchOne(db, key: id) else {
                    Self.logger.warning("Session not found for analysis path update: \(id)")
                    return
                }
                record.analysisPath = analysisPath
                try record.update(db)
            }
        } catch {
            Self.logger.error("Failed to update analysis path for \(id): \(error)")
        }
    }

    /// Persists a corrected recording type for a session.
    ///
    /// - Parameters:
    ///   - id: Session identifier.
    ///   - recordingType: New recording-type raw value (e.g. "lecture").
    func updateRecordingType(id: String, recordingType: String) {
        do {
            try database.dbPool.write { db in
                guard var record = try SessionRecord.fetchOne(db, key: id) else {
                    Self.logger.warning("Session not found for recording type update: \(id)")
                    return
                }
                record.recordingType = recordingType
                try record.update(db)
            }

            // Keep the in-memory list in sync (preserves all other fields).
            if let index = recentSessions.firstIndex(where: { $0.id == id }) {
                recentSessions[index].recordingType = recordingType
            }
        } catch {
            Self.logger.error("Failed to update recording type for \(id): \(error)")
        }
    }

    /// Updates the status (and optional error message) for a session.
    ///
    /// - Parameters:
    ///   - id: Session identifier.
    ///   - status: New status string (e.g. "transcribing", "transcribed", "error").
    ///   - errorMessage: Optional error description to persist.
    func updateSessionStatus(
        id: String,
        status: String,
        errorMessage: String? = nil
    ) {
        do {
            try database.dbPool.write { db in
                guard var record = try SessionRecord.fetchOne(db, key: id) else {
                    Self.logger.warning("Session not found for status update: \(id)")
                    return
                }
                record.status = status
                record.errorMessage = errorMessage
                try record.update(db)
            }

            // Keep the in-memory list in sync.
            if let index = recentSessions.firstIndex(where: { $0.id == id }) {
                let existing = recentSessions[index]
                recentSessions[index] = Session(
                    id: existing.id,
                    title: existing.title,
                    sourceApp: existing.sourceApp,
                    startedAt: existing.startedAt,
                    endedAt: existing.endedAt,
                    durationSec: existing.durationSec,
                    audioPath: existing.audioPath,
                    recordingType: existing.recordingType,
                    analysisPath: existing.analysisPath,
                    status: status
                )
            }

            Self.logger.info("Session \(id) status updated to '\(status)'")
        } catch {
            Self.logger.error("Failed to update session status for \(id): \(error)")
        }
    }

    // MARK: - Private Helpers

    private func loadRecentSessions() {
        do {
            recentSessions = try database.dbPool.read { db in
                let records = try SessionRecord
                    .orderedByDate()
                    .limit(50)
                    .fetchAll(db)
                return records.map { $0.toSession() }
            }
            Self.logger.info("Loaded \(self.recentSessions.count) recent sessions")
        } catch {
            Self.logger.error("Failed to load recent sessions: \(error)")
        }
    }

    private func createDirectoriesIfNeeded() {
        let manager = FileManager.default
        let dirs = [
            storageDirectory,
            storageDirectory.appendingPathComponent("audio"),
            storageDirectory.appendingPathComponent("transcripts/raw"),
            storageDirectory.appendingPathComponent("transcripts/markdown"),
        ]
        for dir in dirs {
            try? manager.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
        }
    }
}
