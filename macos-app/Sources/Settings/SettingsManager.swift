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

    /// Legacy single-key field, used by Groq/OpenAI Whisper.
    var remoteApiKey: String = "" {
        didSet {
            saveSecretIfReady(remoteApiKey, for: "remote_api_key")
        }
    }

    /// AssemblyAI key — split from `remoteApiKey` so the user can hold both
    /// AssemblyAI + Deepgram credentials at once and the `.auto` provider can
    /// pick between them at transcribe time based on `session.language`.
    var assemblyAIApiKey: String = "" {
        didSet {
            saveSecretIfReady(assemblyAIApiKey, for: "assemblyai_api_key")
        }
    }

    /// Deepgram key (see `assemblyAIApiKey`).
    var deepgramApiKey: String = "" {
        didSet {
            saveSecretIfReady(deepgramApiKey, for: "deepgram_api_key")
        }
    }

    var llmEngine: LLMEngine = .claude { didSet { persist("llm_engine", llmEngine.rawValue) } }

    var llmApiKey: String = "" {
        didSet {
            saveSecretIfReady(llmApiKey, for: "llm_api_key")
        }
    }

    var llmProvider: LLMProvider = .openrouter { didSet { persist("llm_provider", llmProvider.rawValue) } }

    var openRouterApiKey: String = "" {
        didSet {
            saveSecretIfReady(openRouterApiKey, for: "openrouter_api_key")
        }
    }

    var llmModel: String = "google/gemini-2.5-flash" {
        didSet { persist("llm_model", llmModel) }
    }

    var localLLMBaseURL: String = "http://localhost:11434/v1" {
        didSet { persist("local_llm_base_url", localLLMBaseURL) }
    }

    // MARK: - Real-time Meeting Assistant

    var assistantLLMPreset: LLMProviderPreset = .openRouter {
        didSet { persist("assistant_llm_preset", assistantLLMPreset.rawValue) }
    }
    var assistantLLMBaseURL: String = LLMProviderPreset.openRouter.defaultBaseURL {
        didSet { persist("assistant_llm_base_url", assistantLLMBaseURL) }
    }
    var assistantLLMModel: String = LLMProviderPreset.openRouter.defaultModel {
        didSet { persist("assistant_llm_model", assistantLLMModel) }
    }
    var assistantLLMAPIKey: String = "" {
        didSet {
            saveSecretIfReady(assistantLLMAPIKey, for: LLMConfiguration.keychainAccount)
        }
    }
    var assistantLLMTimeout: Double = 30 {
        didSet { persist("assistant_llm_timeout", String(assistantLLMTimeout)) }
    }
    var assistantLLMMaxTokens: Int = 600 {
        didSet { persist("assistant_llm_max_tokens", String(assistantLLMMaxTokens)) }
    }
    var assistantLLMTemperature: Double = 0.3 {
        didSet { persist("assistant_llm_temperature", String(assistantLLMTemperature)) }
    }
    /// Prompt text remains memory-only under the assistant privacy boundary.
    var assistantSystemPrompt: String = SettingsManager.defaultAssistantSystemPrompt
    var assistantContextDuration: Double = 30 {
        didSet { persist("assistant_context_duration", String(assistantContextDuration)) }
    }

    var assistantLLMConfiguration: LLMConfiguration {
        LLMConfiguration(
            preset: assistantLLMPreset,
            baseURL: assistantLLMBaseURL,
            model: assistantLLMModel,
            apiKey: assistantLLMAPIKey,
            timeout: assistantLLMTimeout,
            maxTokens: assistantLLMMaxTokens,
            temperature: assistantLLMTemperature,
            systemPrompt: assistantSystemPrompt,
            contextDuration: assistantContextDuration
        )
    }

    func applyAssistantLLMPreset(_ preset: LLMProviderPreset) {
        assistantLLMPreset = preset
        guard preset != .custom else { return }
        assistantLLMBaseURL = preset.defaultBaseURL
        assistantLLMModel = preset.defaultModel
    }

    // MARK: - Pricing (USD). Defaults mirror python-worker/app/postprocess/pricing.py.
    var sttRateAssemblyAI: Double = 0.0035 { didSet { persist("stt_rate_assemblyai", String(sttRateAssemblyAI)) } }
    var sttRateDeepgram: Double = 0.0043 { didSet { persist("stt_rate_deepgram", String(sttRateDeepgram)) } }
    var sttRateOpenAI: Double = 0.0060 { didSet { persist("stt_rate_openai", String(sttRateOpenAI)) } }
    var sttRateGroq: Double = 0.0007 { didSet { persist("stt_rate_groq", String(sttRateGroq)) } }
    var llmFallbackRatePer1M: Double = 3.00 { didSet { persist("llm_fallback_rate_per_1m", String(llmFallbackRatePer1M)) } }

    /// STT $/min keyed by the worker's provider names, for the JobRequest.
    var sttRatesPerMin: [String: Double] {
        [
            "assemblyai": sttRateAssemblyAI,
            "deepgram": sttRateDeepgram,
            "openai": sttRateOpenAI,
            "groq": sttRateGroq,
            "local_whisper": 0.0,
        ]
    }

    func resetPricingToDefaults() {
        sttRateAssemblyAI = 0.0035
        sttRateDeepgram = 0.0043
        sttRateOpenAI = 0.0060
        sttRateGroq = 0.0007
        llmFallbackRatePer1M = 3.00
    }

    var outputDirectory: String = defaultOutputDirectory { didSet { persist("output_directory", outputDirectory) } }
    var obsidianExportDirectory: String = "" { didSet { persist("obsidian_export_directory", obsidianExportDirectory) } }
    var obsidianFolderPattern: String = "_meetings/{YYYY-MM}/" { didSet { persist("obsidian_folder_pattern", obsidianFolderPattern) } }
    var autoProcessOnStop: Bool = true { didSet { persist("auto_process_on_stop", String(autoProcessOnStop)) } }
    var keepSeparateMicTrack: Bool = false { didSet { persist("keep_separate_mic_track", String(keepSeparateMicTrack)) } }
    var diarizationModelsReady: Bool = false { didSet { persist("diarization_models_ready", String(diarizationModelsReady)) } }
    var emotionModelsReady: Bool = false { didSet { persist("emotion_models_ready", String(emotionModelsReady)) } }
    var markdownProfile: MarkdownProfile = .meetingNotes { didSet { persist("markdown_profile", markdownProfile.rawValue) } }

    private let database: AppDatabase
    private let loadSecret: (String) -> String
    private let saveSecret: (String, String) -> Void
    private var isLoadingSecrets = false
    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "SettingsManager"
    )

    private static let defaultAssistantSystemPrompt = """
        Give concise, practical help for a live meeting. Offer a few useful ideas and, when helpful, a short phrase the user can say directly.
        """

    /// Creates the settings manager and loads persisted values.
    ///
    /// - Parameter database: The GRDB-backed application database.
    init(
        database: AppDatabase,
        loadSecret: @escaping (String) -> String = { KeychainHelper.load(for: $0) },
        saveSecret: @escaping (String, String) -> Void = { value, account in
            KeychainHelper.save(value, for: account)
        }
    ) {
        self.database = database
        self.loadSecret = loadSecret
        self.saveSecret = saveSecret
        isLoadingSecrets = true
        loadAll()
        isLoadingSecrets = false
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

    private func saveSecretIfReady(_ value: String, for account: String) {
        guard !isLoadingSecrets else { return }
        saveSecret(value, account)
        persist(account, "keychain")
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
        if let raw = rows["auto_process_on_stop"] { autoProcessOnStop = raw == "true" }
        if let raw = rows["keep_separate_mic_track"] { keepSeparateMicTrack = raw == "true" }
        if let raw = rows["diarization_models_ready"] { diarizationModelsReady = raw == "true" }
        if let raw = rows["emotion_models_ready"] { emotionModelsReady = raw == "true" }
        if let raw = rows["markdown_profile"], let val = MarkdownProfile(rawValue: raw) { markdownProfile = val }
        if let raw = rows["llm_provider"], let val = LLMProvider(rawValue: raw) { llmProvider = val }
        if let raw = rows["llm_model"], !raw.isEmpty { llmModel = raw }
        if let raw = rows["local_llm_base_url"], !raw.isEmpty { localLLMBaseURL = raw }
        if let raw = rows["assistant_llm_preset"], let val = LLMProviderPreset(rawValue: raw) { assistantLLMPreset = val }
        if let raw = rows["assistant_llm_base_url"] { assistantLLMBaseURL = raw }
        if let raw = rows["assistant_llm_model"] { assistantLLMModel = raw }
        if let raw = rows["assistant_llm_timeout"], let val = Double(raw) { assistantLLMTimeout = val }
        if let raw = rows["assistant_llm_max_tokens"], let val = Int(raw) { assistantLLMMaxTokens = val }
        if let raw = rows["assistant_llm_temperature"], let val = Double(raw) { assistantLLMTemperature = val }
        if let raw = rows["assistant_context_duration"], let val = Double(raw) { assistantContextDuration = val }
        if let raw = rows["stt_rate_assemblyai"], let v = Double(raw) { sttRateAssemblyAI = v }
        if let raw = rows["stt_rate_deepgram"], let v = Double(raw) { sttRateDeepgram = v }
        if let raw = rows["stt_rate_openai"], let v = Double(raw) { sttRateOpenAI = v }
        if let raw = rows["stt_rate_groq"], let v = Double(raw) { sttRateGroq = v }
        if let raw = rows["llm_fallback_rate_per_1m"], let v = Double(raw) { llmFallbackRatePer1M = v }

        // API keys live in Keychain, not SQLite.
        remoteApiKey = loadSecret("remote_api_key")
        assemblyAIApiKey = loadSecret("assemblyai_api_key")
        deepgramApiKey = loadSecret("deepgram_api_key")
        llmApiKey = loadSecret("llm_api_key")
        openRouterApiKey = loadSecret("openrouter_api_key")
        assistantLLMAPIKey = loadSecret(LLMConfiguration.keychainAccount)

        Self.logger.info("Settings loaded (\(rows.count) persisted keys)")
    }
}
