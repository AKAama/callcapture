import Foundation
import Testing
@testable import CallCapture

@Suite("LLM configuration")
struct LLMConfigurationTests {
    @Test("all supported provider presets have editable defaults")
    func presets() {
        #expect(LLMProviderPreset.allCases == [.openAI, .openRouter, .deepSeek, .ollama, .custom])
        #expect(LLMProviderPreset.openAI.defaultBaseURL == "https://api.openai.com/v1")
        #expect(LLMProviderPreset.openRouter.defaultBaseURL == "https://openrouter.ai/api/v1")
        #expect(LLMProviderPreset.deepSeek.defaultBaseURL == "https://api.deepseek.com/v1")
        #expect(LLMProviderPreset.ollama.defaultBaseURL == "http://localhost:11434/v1")
        #expect(LLMProviderPreset.custom.defaultBaseURL == "")
        #expect(!LLMProviderPreset.openAI.defaultModel.isEmpty)
        #expect(!LLMProviderPreset.openRouter.defaultModel.isEmpty)
        #expect(!LLMProviderPreset.deepSeek.defaultModel.isEmpty)
        #expect(!LLMProviderPreset.ollama.defaultModel.isEmpty)
    }

    @Test("only absolute HTTP and HTTPS base URLs are accepted")
    func baseURLValidation() throws {
        let valid = configuration(baseURL: "http://localhost:11434/v1/")
        #expect(try valid.chatCompletionsURL().absoluteString == "http://localhost:11434/v1/chat/completions")

        for invalid in ["", "localhost:11434/v1", "file:///tmp/api", "https:///v1"] {
            do {
                _ = try configuration(baseURL: invalid).chatCompletionsURL()
                Issue.record("Expected invalid URL: \(invalid)")
            } catch {
                #expect(error as? LLMConfigurationError == .invalidBaseURL)
            }
        }
    }

    @Test("plaintext HTTP is limited to keyless loopback endpoints")
    func secureTransportValidation() {
        for baseURL in [
            "http://localhost:11434/v1",
            "http://localhost.:11434/v1",
            "http://127.0.0.2:11434/v1",
            "http://[::1]:11434/v1",
        ] {
            #expect(configuration(baseURL: baseURL, apiKey: "").validationError == nil)
        }

        #expect(configuration(baseURL: "https://example.com/v1", apiKey: "secret").validationError == nil)
        #expect(configuration(baseURL: "http://example.com/v1", apiKey: "").validationError == .insecureTransport)
        #expect(configuration(baseURL: "http://localhost:11434/v1", apiKey: "secret").validationError == .insecureTransport)
        #expect(configuration(baseURL: "http://127.0.0.1.example.com/v1", apiKey: "").validationError == .insecureTransport)
    }

    @Test("cloud providers require a key while local Ollama allows an empty key")
    func optionalLocalKey() {
        #expect(LLMProviderPreset.openAI.requiresAPIKey)
        #expect(LLMProviderPreset.openRouter.requiresAPIKey)
        #expect(LLMProviderPreset.deepSeek.requiresAPIKey)
        #expect(!LLMProviderPreset.ollama.requiresAPIKey)

        #expect(configuration(preset: .ollama, apiKey: "").validationError == nil)
        #expect(configuration(preset: .openAI, apiKey: "  ").validationError == .missingAPIKey)
    }

    @Test("assistant secret uses a dedicated stable Keychain account")
    func keychainAccount() {
        #expect(LLMConfiguration.keychainAccount == "assistant_llm_api_key")
    }


    @Test("loading Keychain secrets does not write them back")
    func settingsInitializationDoesNotWriteSecrets() throws {
        let path = NSTemporaryDirectory() + "cc-assistant-settings-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = try AppDatabase(path: path)
        let saves = SettingsSaveRecorder()

        let settings = SettingsManager(
            database: database,
            loadSecret: { account in
                account == LLMConfiguration.keychainAccount ? "loaded-secret" : ""
            },
            saveSecret: { value, account in
                saves.record(value: value, account: account)
            }
        )

        #expect(settings.assistantLLMAPIKey == "loaded-secret")
        #expect(saves.values.isEmpty)

        settings.assistantLLMAPIKey = "replacement"
        #expect(saves.values == [LLMConfiguration.keychainAccount: "replacement"])
    }

    private func configuration(
        preset: LLMProviderPreset = .custom,
        baseURL: String = "https://example.com/v1",
        apiKey: String = "secret"
    ) -> LLMConfiguration {
        LLMConfiguration(
            preset: preset,
            baseURL: baseURL,
            model: "test-model",
            apiKey: apiKey,
            timeout: 10,
            maxTokens: 128,
            temperature: 0.2,
            systemPrompt: "Be concise.",
            contextDuration: 30
        )
    }
}

private final class SettingsSaveRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]

    var values: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(value: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        stored[account] = value
    }
}
