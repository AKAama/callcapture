import Foundation
import GRDB
import OSLog

/// Manages application settings backed by the GRDB `settings` table
/// and Keychain for sensitive values (API keys).
///
/// Every property change is persisted immediately. API keys are stored
/// in the Keychain; only a reference marker is kept in SQLite.
@Observable
final class SettingsManager {

    var defaultEngine: TranscriptionEngine = .localWhisper { didSet { persist("default_engine", defaultEngine.rawValue) } }
    var whisperModel: WhisperModel = .base { didSet { persist("whisper_model", whisperModel.rawValue) } }
    var remoteProvider: RemoteProvider = .groq { didSet { persist("remote_provider", remoteProvider.rawValue) } }

    var remoteApiKey: String = "" {
        didSet {
            KeychainHelper.save(remoteApiKey, for: "remote_api_key")
            persist("remote_api_key", "keychain")
        }
    }

    var llmEngine: LLMEngine = .claude { didSet { persist("llm_engine", llmEngine.rawValue) } }

    var llmApiKey: String = "" {
        didSet {
            KeychainHelper.save(llmApiKey, for: "llm_api_key")
            persist("llm_api_key", "keychain")
        }
    }

    var llmProvider: LLMProvider = .openrouter { didSet { persist("llm_provider", llmProvider.rawValue) } }

    var openRouterApiKey: String = "" {
        didSet {
            KeychainHelper.save(openRouterApiKey, for: "openrouter_api_key")
            persist("openrouter_api_key", "keychain")
        }
    }

    var llmModel: String = "google/gemini-2.5-flash" {
        didSet { persist("llm_model", llmModel) }
    }

    var localLLMBaseURL: String = "http://localhost:11434/v1" {
        didSet { persist("local_llm_base_url", localLLMBaseURL) }
    }

    var outputDirectory: String = defaultOutputDirectory { didSet { persist("output_directory", outputDirectory) } }
    var obsidianExportDirectory: String = "" { didSet { persist("obsidian_export_directory", obsidianExportDirectory) } }
    var obsidianFolderPattern: String = "_meetings/{YYYY-MM}/" { didSet { persist("obsidian_folder_pattern", obsidianFolderPattern) } }
    var enableDiarization: Bool = false { didSet { persist("enable_diarization", String(enableDiarization)) } }
    var autoProcessOnStop: Bool = true { didSet { persist("auto_process_on_stop", String(autoProcessOnStop)) } }
    var keepSeparateMicTrack: Bool = false { didSet { persist("keep_separate_mic_track", String(keepSeparateMicTrack)) } }
    var markdownProfile: MarkdownProfile = .meetingNotes { didSet { persist("markdown_profile", markdownProfile.rawValue) } }

    private let database: AppDatabase
    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "SettingsManager"
    )

    /// Creates the settings manager and loads persisted values.
    ///
    /// - Parameter database: The GRDB-backed application database.
    init(database: AppDatabase) {
        self.database = database
        loadAll()
    }

    // MARK: - Private Helpers

    private static var defaultOutputDirectory: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return appSupport
            .appendingPathComponent("CallCapture", isDirectory: true)
            .path
    }

    private func persist(_ key: String, _ value: String) {
        do {
            try database.dbPool.write { db in
                try db.execute(
                    sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                    arguments: [key, value]
                )
            }
        } catch {
            Self.logger.error("Failed to persist setting '\(key)': \(error)")
        }
    }

    private func loadAll() {
        let rows: [String: String]
        do {
            rows = try database.dbPool.read { db in
                var result: [String: String] = [:]
                let cursor = try Row.fetchCursor(db, sql: "SELECT key, value FROM settings")
                while let row = try cursor.next() {
                    let key: String = row["key"]
                    let value: String = row["value"]
                    result[key] = value
                }
                return result
            }
        } catch {
            Self.logger.error("Failed to load settings: \(error)")
            return
        }

        if let raw = rows["default_engine"], let val = TranscriptionEngine(rawValue: raw) { defaultEngine = val }
        if let raw = rows["whisper_model"], let val = WhisperModel(rawValue: raw) { whisperModel = val }
        if let raw = rows["remote_provider"], let val = RemoteProvider(rawValue: raw) { remoteProvider = val }
        if let raw = rows["llm_engine"], let val = LLMEngine(rawValue: raw) { llmEngine = val }
        if let raw = rows["output_directory"], !raw.isEmpty { outputDirectory = raw }
        if let raw = rows["obsidian_export_directory"] { obsidianExportDirectory = raw }
        if let raw = rows["obsidian_folder_pattern"], !raw.isEmpty { obsidianFolderPattern = raw }
        if let raw = rows["enable_diarization"] { enableDiarization = raw == "true" }
        if let raw = rows["auto_process_on_stop"] { autoProcessOnStop = raw == "true" }
        if let raw = rows["keep_separate_mic_track"] { keepSeparateMicTrack = raw == "true" }
        if let raw = rows["markdown_profile"], let val = MarkdownProfile(rawValue: raw) { markdownProfile = val }
        if let raw = rows["llm_provider"], let val = LLMProvider(rawValue: raw) { llmProvider = val }
        if let raw = rows["llm_model"], !raw.isEmpty { llmModel = raw }
        if let raw = rows["local_llm_base_url"], !raw.isEmpty { localLLMBaseURL = raw }

        // API keys live in Keychain, not SQLite.
        remoteApiKey = KeychainHelper.load(for: "remote_api_key")
        llmApiKey = KeychainHelper.load(for: "llm_api_key")
        openRouterApiKey = KeychainHelper.load(for: "openrouter_api_key")

        Self.logger.info("Settings loaded (\(rows.count) persisted keys)")
    }
}
