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
