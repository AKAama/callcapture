import Foundation
import OSLog

enum OpenAICompatibleClientError: Error, Equatable, LocalizedError {
    case unauthorized
    case rateLimited
    case httpStatus(Int)
    case insecureTransport
    case invalidResponse
    case timedOut
    case transport

    var errorDescription: String? {
        switch self {
        case .unauthorized: "The provider rejected the API key (401)."
        case .rateLimited: "The provider rate limit was reached (429)."
        case .httpStatus(let status): "The provider returned HTTP \(status)."
        case .insecureTransport: "The provider connection is not secure."
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
        case .insecureTransport: "insecure_transport"
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
                    let redirectDelegate = SecureLLMRedirectDelegate(
                        originalURL: request.url!,
                        apiKey: configuration.apiKey
                    )
                    let (bytes, response) = try await session.bytes(
                        for: request,
                        delegate: redirectDelegate
                    )
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw OpenAICompatibleClientError.invalidResponse
                    }
                    let status = httpResponse.statusCode
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

                    let contentType = httpResponse
                        .value(forHTTPHeaderField: "Content-Type")?
                        .split(separator: ";", maxSplits: 1)
                        .first?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    guard contentType == "text/event-stream" else {
                        throw OpenAICompatibleClientError.invalidResponse
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
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAICompatibleClientError.invalidResponse
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
        var dataLines: [String] = []
        var sawDataEvent = false
        var pendingCarriageReturn = false

        func finishLine() throws -> Bool {
            defer { line.removeAll(keepingCapacity: true) }
            guard try collectDataField(from: line, into: &dataLines) else { return false }
            guard !dataLines.isEmpty else { return false }

            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            sawDataEvent = true
            return try consume(eventPayload: payload, continuation: continuation)
        }

        for try await byte in bytes {
            try Task.checkCancellation()

            if pendingCarriageReturn {
                pendingCarriageReturn = false
                if try finishLine() { return }
                if byte == 0x0A { continue }
            }

            switch byte {
            case 0x0D:
                pendingCarriageReturn = true
            case 0x0A:
                if try finishLine() { return }
            default:
                line.append(byte)
            }
        }

        if pendingCarriageReturn, try finishLine() {
            return
        }
        guard sawDataEvent else { throw OpenAICompatibleClientError.invalidResponse }
    }

    /// Collects one SSE `data` field. Returns true only for a blank event delimiter.
    private func collectDataField(from line: Data, into dataLines: inout [String]) throws -> Bool {
        guard let text = String(data: line, encoding: .utf8) else {
            throw OpenAICompatibleClientError.invalidResponse
        }
        guard !text.isEmpty else { return true }
        guard !text.hasPrefix(":") else { return false }

        let pieces = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.first == "data" else { return false }
        var value = pieces.count == 2 ? String(pieces[1]) : ""
        if value.first == " " { value.removeFirst() }
        dataLines.append(value)
        return false
    }

    /// Parses one fully framed SSE event. Returns true for terminal `[DONE]`.
    private func consume(
        eventPayload payload: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws -> Bool {
        if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { return true }
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else {
            throw OpenAICompatibleClientError.invalidResponse
        }

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
        if let error = error as? LLMConfigurationError, error == .insecureTransport {
            return .insecureTransport
        }
        if let error = error as? URLError, error.code == .timedOut { return .timedOut }
        return .transport
    }
}

/// Applies the same transport rule to redirects as initial configuration validation.
final class SecureLLMRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private struct Origin: Equatable, Sendable {
        let scheme: String
        let host: String
        let port: Int

        init?(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(),
                  var host = url.host?.lowercased() else {
                return nil
            }
            if host.hasSuffix(".") { host.removeLast() }
            let defaultPort: Int
            switch scheme {
            case "https": defaultPort = 443
            case "http": defaultPort = 80
            default: return nil
            }
            self.scheme = scheme
            self.host = host
            self.port = url.port ?? defaultPort
        }
    }

    private let originalOrigin: Origin?
    private let apiKey: String

    init(originalURL: URL, apiKey: String) {
        originalOrigin = Origin(originalURL)
        self.apiKey = apiKey
    }

    func shouldFollowRedirect(to url: URL) -> Bool {
        guard let originalOrigin, Origin(url) == originalOrigin else { return false }
        return LLMConfiguration.isAllowedTransport(to: url, apiKey: apiKey)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(shouldFollowRedirect(to:)) == true ? request : nil)
    }
}
