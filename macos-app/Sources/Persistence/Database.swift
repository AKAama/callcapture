import Foundation
import GRDB
import OSLog

/// Manages the GRDB database pool and schema migrations.
///
/// The database is stored at `~/Library/Application Support/CallCapture/callcapture.db`.
/// All schema changes go through `DatabaseMigrator` for versioned, forward-only migrations.
final class AppDatabase: Sendable {

    /// The underlying GRDB database pool for concurrent reads.
    let dbPool: DatabasePool

    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "AppDatabase"
    )

    /// Opens (or creates) the database at the default application support path.
    ///
    /// - Throws: A database error if the file cannot be opened or migrations fail.
    init() throws {
        let directory = AppDatabase.databaseDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let path = directory.appendingPathComponent("callcapture.db").path
        let dbPool = try DatabasePool(path: path)
        self.dbPool = dbPool

        try AppDatabase.migrator.migrate(dbPool)
        Self.logger.info("Database opened at \(path)")
    }

    /// Opens a database pool at a caller-specified path (useful for testing).
    ///
    /// - Parameter path: Absolute filesystem path for the SQLite file.
    /// - Throws: A database error if the file cannot be opened or migrations fail.
    init(path: String) throws {
        let dbPool = try DatabasePool(path: path)
        self.dbPool = dbPool

        try AppDatabase.migrator.migrate(dbPool)
        Self.logger.info("Database opened at \(path)")
    }

    // MARK: - Private Helpers

    private static func databaseDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return appSupport.appendingPathComponent("CallCapture", isDirectory: true)
    }

    /// Versioned migrator. Each migration runs exactly once, in order.
    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_createTables") { db in
            try db.create(table: "session") { table in
                table.primaryKey("id", .text)
                table.column("title", .text).notNull()
                table.column("source_app", .text).notNull()
                table.column("capture_mode", .text).notNull().defaults(to: "default_output")
                table.column("started_at", .text).notNull()
                table.column("ended_at", .text)
                table.column("duration_sec", .double)
                table.column("audio_path", .text).notNull()
                table.column("transcript_raw_path", .text)
                table.column("transcript_markdown_path", .text)
                table.column("engine_used", .text)
                table.column("status", .text).notNull().defaults(to: "recording")
                table.column("error_message", .text)
            }

            try db.create(table: "job") { table in
                table.primaryKey("id", .text)
                table.column("session_id", .text)
                    .notNull()
                    .references("session", onDelete: .cascade)
                table.column("type", .text).notNull()
                table.column("status", .text).notNull().defaults(to: "pending")
                table.column("started_at", .text).notNull()
                table.column("ended_at", .text)
                table.column("attempt_count", .integer).notNull().defaults(to: 0)
                table.column("warnings_json", .text)
            }

            try db.create(table: "settings") { table in
                table.primaryKey("key", .text)
                table.column("value", .text).notNull()
            }
        }

        migrator.registerMigration("v2_recordingTypeAndAnalysis") { db in
            try db.alter(table: "session") { table in
                table.add(column: "recording_type", .text)
                    .notNull()
                    .defaults(to: "call_meeting")
                table.add(column: "analysis_path", .text)
            }
        }

        return migrator
    }
}
