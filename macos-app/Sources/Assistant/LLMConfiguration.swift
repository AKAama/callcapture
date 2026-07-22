import Foundation

/// Editable defaults for services that implement OpenAI Chat Completions.
enum LLMProviderPreset: String, Codable, CaseIterable, Sendable {
    case openAI = "openai"
    case openRouter = "openrouter"
    case deepSeek = "deepseek"
    case ollama
    case custom

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .deepSeek: "DeepSeek"
        case .ollama: "Ollama (local)"
        case .custom: "Custom"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .deepSeek: "https://api.deepseek.com/v1"
        case .ollama: "http://localhost:11434/v1"
        case .custom: ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: "gpt-4o-mini"
        case .openRouter: "google/gemini-2.5-flash"
        case .deepSeek: "deepseek-chat"
        case .ollama: "qwen2.5:7b"
        case .custom: ""
        }
    }

    /// Custom endpoints can be local and unauthenticated, just like Ollama.
    var requiresAPIKey: Bool {
        switch self {
        case .openAI, .openRouter, .deepSeek: true
        case .ollama, .custom: false
        }
    }
}

enum LLMConfigurationError: Error, Equatable, LocalizedError {
    case invalidBaseURL
    case missingModel
    case missingAPIKey
    case invalidTimeout
    case invalidMaxTokens
    case invalidTemperature
    case invalidContextDuration

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "Enter an absolute HTTP or HTTPS base URL."
        case .missingModel: "Enter a model identifier."
        case .missingAPIKey: "Enter an API key for this provider."
        case .invalidTimeout: "Timeout must be greater than zero."
        case .invalidMaxTokens: "Maximum output tokens must be greater than zero."
        case .invalidTemperature: "Temperature must be between 0 and 2."
        case .invalidContextDuration: "Context duration must be greater than zero."
        }
    }
}

/// All settings needed for one assistant request. Callers must keep this value
/// in memory: `apiKey`, prompts, and messages are never persistence payloads.
struct LLMConfiguration: Equatable, Sendable {
    static let keychainAccount = "assistant_llm_api_key"

    var preset: LLMProviderPreset
    var baseURL: String
    var model: String
    var apiKey: String
    var timeout: TimeInterval
    var maxTokens: Int
    var temperature: Double
    var systemPrompt: String
    var contextDuration: TimeInterval

    var validationError: LLMConfigurationError? {
        do {
            try validate()
            return nil
        } catch let error as LLMConfigurationError {
            return error
        } catch {
            return .invalidBaseURL
        }
    }

    func validate() throws {
        _ = try chatCompletionsURL()
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMConfigurationError.missingModel
        }
        if preset.requiresAPIKey,
           apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LLMConfigurationError.missingAPIKey
        }
        guard timeout > 0 else { throw LLMConfigurationError.invalidTimeout }
        guard maxTokens > 0 else { throw LLMConfigurationError.invalidMaxTokens }
        guard (0...2).contains(temperature) else {
            throw LLMConfigurationError.invalidTemperature
        }
        guard contextDuration > 0 else {
            throw LLMConfigurationError.invalidContextDuration
        }
    }

    func chatCompletionsURL() throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            throw LLMConfigurationError.invalidBaseURL
        }
        let normalizedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = normalizedPath.isEmpty ? "" : "/\(normalizedPath)"
        guard let base = components.url else {
            throw LLMConfigurationError.invalidBaseURL
        }
        return base.appendingPathComponent("chat/completions")
    }
}

struct LLMMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    let role: Role
    let content: String
}
