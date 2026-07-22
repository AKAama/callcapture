import Foundation
import Testing
@testable import CallCapture

@Suite("OpenAI-compatible streaming client", .serialized)
struct OpenAICompatibleClientTests {
    @Test("parses arbitrarily split data events and stops at DONE")
    func parsesSplitSSE() async throws {
        let session = makeSession { protocolClient, protocolInstance, request in
            respond(status: 200, request: request, client: protocolClient, protocol: protocolInstance)
            let fragments = [
                "da", "ta: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n",
                "\n: keepalive\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}",
                "\n\ndata: [DO", "NE]\n\n",
                "data: {\"choices\":[{\"delta\":{\"content\":\"ignored\"}}]}\n\n",
            ]
            for fragment in fragments {
                protocolClient.urlProtocol(protocolInstance, didLoad: Data(fragment.utf8))
            }
            protocolClient.urlProtocolDidFinishLoading(protocolInstance)
        }
        defer { session.invalidateAndCancel() }

        let chunks = try await collect(OpenAICompatibleClient(session: session).stream(
            messages: [.init(role: .user, content: "request-marker")],
            configuration: configuration()
        ))

        #expect(chunks == ["Hel", "lo"])
    }

    @Test("frames SSE events across data fields and all supported line endings")
    func parsesFramedMultilineSSE() async throws {
        let session = makeSession { protocolClient, protocolInstance, request in
            respond(status: 200, request: request, client: protocolClient, protocol: protocolInstance)
            let fragments = [
                "data: {\"choices\":[\rda",
                "ta: {\"delta\":{\"content\":\"multi\"}}\rdata: ]}\r\r",
                ": keepalive\r\nevent: message\r\ndata: {\"choices\":[{\"delta\":",
                "{\"content\":\"line\"}}]}\r\n\r\ndata: [DO",
                "NE]\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"ignored\"}}]}\n\n",
            ]
            for fragment in fragments {
                protocolClient.urlProtocol(protocolInstance, didLoad: Data(fragment.utf8))
            }
            protocolClient.urlProtocolDidFinishLoading(protocolInstance)
        }
        defer { session.invalidateAndCancel() }

        let chunks = try await collect(OpenAICompatibleClient(session: session).stream(
            messages: [.init(role: .user, content: "request-marker")],
            configuration: configuration()
        ))

        #expect(chunks == ["multi", "line"])
    }

    @Test("request body contains only the supported Chat Completions fields")
    func exactRequestBody() async throws {
        let requestBody = LockedBox<Data?>(nil)
        let authorization = LockedBox<String?>(nil)
        let session = makeSession { protocolClient, protocolInstance, request in
            requestBody.withValue { $0 = requestBodyData(for: request) }
            authorization.withValue { $0 = request.value(forHTTPHeaderField: "Authorization") }
            respond(status: 200, request: request, client: protocolClient, protocol: protocolInstance)
            protocolClient.urlProtocol(protocolInstance, didLoad: Data("data: [DONE]\n\n".utf8))
            protocolClient.urlProtocolDidFinishLoading(protocolInstance)
        }
        defer { session.invalidateAndCancel() }

        _ = try await collect(OpenAICompatibleClient(session: session).stream(
            messages: [
                .init(role: .system, content: "system-marker"),
                .init(role: .user, content: "user-marker"),
            ],
            configuration: configuration()
        ))

        let data = try #require(requestBody.value)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["model", "messages", "temperature", "max_tokens", "stream"])
        #expect(object["model"] as? String == "test-model")
        #expect(object["stream"] as? Bool == true)
        #expect(object["max_tokens"] as? Int == 321)
        #expect(authorization.value == "Bearer api-secret")
    }

    @Test("empty local key omits Authorization")
    func localKeyIsOptional() async throws {
        let authorization = LockedBox<String?>(nil)
        let session = makeSession { protocolClient, protocolInstance, request in
            authorization.withValue { $0 = request.value(forHTTPHeaderField: "Authorization") }
            respond(status: 200, request: request, client: protocolClient, protocol: protocolInstance)
            protocolClient.urlProtocol(protocolInstance, didLoad: Data("data: [DONE]\n\n".utf8))
            protocolClient.urlProtocolDidFinishLoading(protocolInstance)
        }
        defer { session.invalidateAndCancel() }

        var local = configuration()
        local.preset = .ollama
        local.baseURL = LLMProviderPreset.ollama.defaultBaseURL
        local.apiKey = ""
        _ = try await collect(OpenAICompatibleClient(session: session).stream(
            messages: [.init(role: .user, content: "hi")],
            configuration: local
        ))
        #expect(authorization.value == nil)
    }

    @Test("a keyed plaintext request is rejected before transport")
    func keyedHTTPIsRejectedBeforeTransport() async {
        let requestCount = LockedBox(0)
        let session = makeSession { _, _, _ in
            requestCount.withValue { $0 += 1 }
        }
        defer { session.invalidateAndCancel() }
        var insecure = configuration()
        insecure.baseURL = "http://localhost:11434/v1"

        do {
            _ = try await collect(OpenAICompatibleClient(session: session).stream(
                messages: [.init(role: .user, content: "private-prompt-marker")],
                configuration: insecure
            ))
            Issue.record("Expected insecure keyed configuration to fail")
        } catch {
            #expect(error as? OpenAICompatibleClientError == .insecureTransport)
            #expect(requestCount.value == 0)
        }
    }

    @Test("redirect policy allows only the original scheme, host, and effective port")
    func redirectTransportPolicy() {
        let original = URL(string: "https://example.com/v1/chat/completions")!
        let delegate = SecureLLMRedirectDelegate(originalURL: original, apiKey: "secret")
        #expect(delegate.shouldFollowRedirect(to: URL(string: "https://example.com/other")!))
        #expect(delegate.shouldFollowRedirect(to: URL(string: "https://example.com:443/other")!))
        #expect(!delegate.shouldFollowRedirect(to: URL(string: "https://other.example/v1")!))
        #expect(!delegate.shouldFollowRedirect(to: URL(string: "https://example.com:444/v1")!))
        #expect(!delegate.shouldFollowRedirect(to: URL(string: "http://example.com/v1")!))
    }

    @Test("307 and 308 cross-origin redirects are refused with body and Bearer intact")
    func rejectsCrossOriginBodyPreservingRedirects() throws {
        let original = URL(string: "https://example.com/v1/chat/completions")!
        let destination = URL(string: "https://attacker.example/collect")!
        let delegate = SecureLLMRedirectDelegate(originalURL: original, apiKey: "secret")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: original)

        for status in [307, 308] {
            let response = try #require(HTTPURLResponse(
                url: original,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString]
            ))
            var redirected = URLRequest(url: destination)
            redirected.httpMethod = "POST"
            redirected.setValue("Bearer private-api-key", forHTTPHeaderField: "Authorization")
            redirected.httpBody = Data("private-message-body".utf8)
            let callback = RedirectCallbackRecorder()

            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: redirected
            ) { accepted in
                callback.record(accepted)
            }

            #expect(callback.wasCalled)
            #expect(callback.request == nil)
        }
    }

    @Test("successful HTTP responses must declare an SSE content type")
    func rejectsNonSSESuccess() async {
        let session = makeSession { protocolClient, protocolInstance, request in
            respond(
                status: 200,
                contentType: "application/json",
                request: request,
                client: protocolClient,
                protocol: protocolInstance
            )
            protocolClient.urlProtocol(protocolInstance, didLoad: Data("data: [DONE]\n\n".utf8))
            protocolClient.urlProtocolDidFinishLoading(protocolInstance)
        }
        defer { session.invalidateAndCancel() }

        do {
            _ = try await collect(OpenAICompatibleClient(session: session).stream(
                messages: [.init(role: .user, content: "hi")],
                configuration: configuration()
            ))
            Issue.record("Expected non-SSE response to fail")
        } catch {
            #expect(error as? OpenAICompatibleClientError == .invalidResponse)
        }
    }

    @Test("an empty SSE response is invalid")
    func rejectsEmptySSEResponse() async {
        let session = makeSession { protocolClient, protocolInstance, request in
            respond(status: 200, request: request, client: protocolClient, protocol: protocolInstance)
            protocolClient.urlProtocolDidFinishLoading(protocolInstance)
        }
        defer { session.invalidateAndCancel() }

        do {
            _ = try await collect(OpenAICompatibleClient(session: session).stream(
                messages: [.init(role: .user, content: "hi")],
                configuration: configuration()
            ))
            Issue.record("Expected empty SSE response to fail")
        } catch {
            #expect(error as? OpenAICompatibleClientError == .invalidResponse)
        }
    }

    @Test("maps 401 and 429 without exposing response bodies")
    func mapsHTTPFailures() async {
        for (status, expected) in [
            (401, OpenAICompatibleClientError.unauthorized),
            (429, OpenAICompatibleClientError.rateLimited),
        ] {
            let session = makeSession { protocolClient, protocolInstance, request in
                respond(status: status, request: request, client: protocolClient, protocol: protocolInstance)
                protocolClient.urlProtocol(protocolInstance, didLoad: Data("private-response-marker".utf8))
                protocolClient.urlProtocolDidFinishLoading(protocolInstance)
            }
            defer { session.invalidateAndCancel() }

            do {
                _ = try await collect(OpenAICompatibleClient(session: session).stream(
                    messages: [.init(role: .user, content: "private-prompt-marker")],
                    configuration: configuration()
                ))
                Issue.record("Expected HTTP \(status) to fail")
            } catch {
                #expect(error as? OpenAICompatibleClientError == expected)
                #expect(!String(describing: error).contains("private-response-marker"))
                #expect(!String(describing: error).contains("private-prompt-marker"))
            }
        }
    }

    @Test("consumer cancellation cancels the underlying request")
    func cancellation() async throws {
        let started = LockedBox(false)
        let stopped = LockedBox(false)
        TestURLProtocol.onStop = { stopped.withValue { $0 = true } }
        defer { TestURLProtocol.onStop = nil }
        let session = makeSession { protocolClient, protocolInstance, request in
            started.withValue { $0 = true }
            respond(status: 200, request: request, client: protocolClient, protocol: protocolInstance)
            protocolClient.urlProtocol(protocolInstance, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"one\"}}]}\n\n".utf8))
            // Deliberately keep the response open until cancellation.
        }
        defer { session.invalidateAndCancel() }
        let stream = OpenAICompatibleClient(session: session).stream(
            messages: [.init(role: .user, content: "hi")],
            configuration: configuration()
        )
        let reader = Task {
            for try await _ in stream {}
        }
        try await waitUntil { started.value }
        reader.cancel()
        _ = await reader.result
        try await waitUntil { stopped.value }
        #expect(stopped.value)
    }

    @Test("transport timeouts map to a sanitized timeout error")
    func timeout() async {
        let session = makeSession { protocolClient, protocolInstance, _ in
            protocolClient.urlProtocol(protocolInstance, didFailWithError: URLError(.timedOut))
        }
        defer { session.invalidateAndCancel() }

        do {
            _ = try await collect(OpenAICompatibleClient(session: session).stream(
                messages: [.init(role: .user, content: "private-prompt-marker")],
                configuration: configuration()
            ))
            Issue.record("Expected timeout")
        } catch {
            #expect(error as? OpenAICompatibleClientError == .timedOut)
            #expect(!String(describing: error).contains("private-prompt-marker"))
        }
    }

    @Test("connection test sends only the fixed probe text")
    func connectionTestIsTranscriptFree() async throws {
        let requestBody = LockedBox<Data?>(nil)
        let session = makeSession { protocolClient, protocolInstance, request in
            requestBody.withValue { $0 = requestBodyData(for: request) }
            respond(status: 200, request: request, client: protocolClient, protocol: protocolInstance)
            protocolClient.urlProtocol(protocolInstance, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}\n\ndata: [DONE]\n\n".utf8))
            protocolClient.urlProtocolDidFinishLoading(protocolInstance)
        }
        defer { session.invalidateAndCancel() }

        let result = try await OpenAICompatibleClient(session: session).testConnection(
            configuration: configuration()
        )

        #expect(result == "OK")
        let data = try #require(requestBody.value)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "Reply with OK."]])
        #expect(!String(decoding: data, as: UTF8.self).contains("meeting-transcript-marker"))
    }

    @Test("connection test requires a non-empty reply")
    func connectionTestRejectsEmptyReply() async {
        let session = makeSession { protocolClient, protocolInstance, request in
            respond(status: 200, request: request, client: protocolClient, protocol: protocolInstance)
            protocolClient.urlProtocol(protocolInstance, didLoad: Data("data: [DONE]\n\n".utf8))
            protocolClient.urlProtocolDidFinishLoading(protocolInstance)
        }
        defer { session.invalidateAndCancel() }

        do {
            _ = try await OpenAICompatibleClient(session: session).testConnection(
                configuration: configuration()
            )
            Issue.record("Expected empty probe reply to fail")
        } catch {
            #expect(error as? OpenAICompatibleClientError == .invalidResponse)
        }
    }

    @MainActor
    @Test("stale connection tests cannot overwrite current status")
    func connectionTestIgnoresStaleCompletion() async throws {
        let gate = ConnectionProbeGate()
        let tester = AssistantLLMConnectionTester { configuration in
            try await gate.probe(configuration)
        }
        var first = configuration()
        first.model = "first"
        var second = configuration()
        second.model = "second"

        tester.start(configuration: first)
        try await waitUntilAsync { await gate.firstStarted }
        tester.start(configuration: second)
        try await waitUntilMainActor { tester.status == .failed("second failed") }
        await gate.finishFirst()
        try await Task.sleep(for: .milliseconds(20))

        #expect(tester.status == .failed("second failed"))
        tester.reset()
        #expect(tester.status == .idle)
    }

    private func configuration() -> LLMConfiguration {
        LLMConfiguration(
            preset: .custom,
            baseURL: "https://example.com/v1",
            model: "test-model",
            apiKey: "api-secret",
            timeout: 2,
            maxTokens: 321,
            temperature: 0.25,
            systemPrompt: "system",
            contextDuration: 30
        )
    }
}

private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var chunks: [String] = []
    for try await chunk in stream { chunks.append(chunk) }
    return chunks
}

private func makeSession(
    handler: @escaping (URLProtocolClient, URLProtocol, URLRequest) -> Void
) -> URLSession {
    TestURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TestURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func respond(
    status: Int,
    contentType: String = "text/event-stream",
    request: URLRequest,
    client: URLProtocolClient,
    protocol protocolInstance: URLProtocol
) {
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": contentType]
    )!
    client.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
}

private actor ConnectionProbeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var firstStarted = false

    func probe(_ configuration: LLMConfiguration) async throws -> String {
        if configuration.model == "first" {
            firstStarted = true
            await withCheckedContinuation { continuation = $0 }
            return "OK"
        }
        throw ConnectionProbeError()
    }

    func finishFirst() {
        continuation?.resume()
        continuation = nil
    }
}

private struct ConnectionProbeError: LocalizedError {
    var errorDescription: String? { "second failed" }
}

private final class RedirectCallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    private var acceptedRequest: URLRequest?

    var wasCalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return called
    }

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return acceptedRequest
    }

    func record(_ request: URLRequest?) {
        lock.lock()
        defer { lock.unlock() }
        called = true
        acceptedRequest = request
    }
}

private func requestBodyData(for request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        result.append(buffer, count: count)
    }
    return result
}

private final class TestURLProtocol: URLProtocol {
    static var handler: ((URLProtocolClient, URLProtocol, URLRequest) -> Void)?
    static var onStop: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client, let handler = Self.handler else { return }
        handler(client, self, request)
    }

    override func stopLoading() {
        Self.onStop?()
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func withValue(_ operation: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        operation(&stored)
    }
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func waitUntilAsync(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func waitUntilMainActor(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(10))
    }
}
