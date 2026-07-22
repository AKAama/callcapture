import Foundation
import OSLog

enum OpenAICompatibleClientError: Error, Equatable, LocalizedError {
    case unauthorized
    case rateLimited
    case httpStatus(Int)
    case invalidResponse
    case timedOut
    case transport

    var errorDescription: String? {
        switch self {
        case .unauthorized: "The provider rejected the API key (401)."
        case .rateLimited: "The provider rate limit was reached (429)."
        case .httpStatus(let status): "The provider returned HTTP \(status)."
        case .invalidResponse: "The provider returned an invalid streaming response."
        case .timedOut: "The provider request timed out."
        case .transport: "The provider could not be reached."
        }
    }

    fileprivate var logCategory: String {
        switch self {
        case .unauthorized: "unauthorized"
        case .rateLimited: "rate_limited"
        case .httpStatus: "http_status"
        case .invalidResponse: "invalid_response"
        case .timedOut: "timeout"
        case .transport: "transport"
        }
    }
}

/// Streams text deltas from an OpenAI-compatible Chat Completions endpoint.
/// Request and response content are deliberately absent from all log calls.
struct OpenAICompatibleClient: Sendable {
    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "MeetingAssistantLLM"
    )

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func stream(
        messages: [LLMMessage],
        configuration: LLMConfiguration
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try configuration.validate()
                    let request = try makeRequest(messages: messages, configuration: configuration)
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    Self.logger.info("LLM stream HTTP status=\(status)")
                    switch status {
                    case 200..<300:
                        break
                    case 401:
                        throw OpenAICompatibleClientError.unauthorized
                    case 429:
                        throw OpenAICompatibleClientError.rateLimited
                    default:
                        throw OpenAICompatibleClientError.httpStatus(status)
                    }

                    try await parse(bytes: bytes, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    let sanitized = sanitize(error)
                    Self.logger.error("LLM stream failed category=\(sanitized.logCategory, privacy: .public)")
                    continuation.finish(throwing: sanitized)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Sends a transcript-free probe. This method has no transcript-store
    /// dependency, so the fixed text below is the only possible test content.
    func testConnection(configuration: LLMConfiguration) async throws -> String {
        let probe = LLMMessage(role: .user, content: "Reply with OK.")
        var reply = ""
        for try await chunk in stream(messages: [probe], configuration: configuration) {
            reply += chunk
        }
        return reply
    }

    private func makeRequest(
        messages: [LLMMessage],
        configuration: LLMConfiguration
    ) throws -> URLRequest {
        struct RequestBody: Encodable {
            let model: String
            let messages: [LLMMessage]
            let temperature: Double
            let maxTokens: Int
            let stream: Bool

            enum CodingKeys: String, CodingKey {
                case model
                case messages
                case temperature
                case maxTokens = "max_tokens"
                case stream
            }
        }

        var request = URLRequest(url: try configuration.chatCompletionsURL())
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: configuration.model.trimmingCharacters(in: .whitespacesAndNewlines),
            messages: messages,
            temperature: configuration.temperature,
            maxTokens: configuration.maxTokens,
            stream: true
        ))
        return request
    }

    private func parse(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        var line = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 0x0A {
                if try consume(line: line, continuation: continuation) { return }
                line.removeAll(keepingCapacity: true)
            } else if byte != 0x0D {
                line.append(byte)
            }
        }
        if !line.isEmpty {
            _ = try consume(line: line, continuation: continuation)
        }
    }

    /// Returns true when the terminal `[DONE]` event was consumed.
    private func consume(
        line: Data,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws -> Bool {
        guard let text = String(data: line, encoding: .utf8) else {
            throw OpenAICompatibleClientError.invalidResponse
        }
        guard text.hasPrefix("data:") else { return false }
        let payload = text.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return true }
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { return false }

        struct Envelope: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta
            }
            let choices: [Choice]
        }

        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            for choice in envelope.choices {
                if let content = choice.delta.content, !content.isEmpty {
                    continuation.yield(content)
                }
            }
            return false
        } catch {
            throw OpenAICompatibleClientError.invalidResponse
        }
    }

    private func sanitize(_ error: Error) -> OpenAICompatibleClientError {
        if let error = error as? OpenAICompatibleClientError { return error }
        if let error = error as? URLError, error.code == .timedOut { return .timedOut }
        return .transport
    }
}
