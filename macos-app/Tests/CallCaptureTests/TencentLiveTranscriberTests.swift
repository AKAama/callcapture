import Foundation
import Testing
@testable import CallCapture

@Suite("TencentLiveTranscriber")
struct TencentLiveTranscriberTests {
    @Test("连接成功后进入 live，重复连接返回明确错误")
    func connectsOnce() async throws {
        let connection = FakeTencentWebSocketConnection()
        let transport = FakeTencentWebSocketTransport([.connection(connection)])
        let scheduler = FakeTencentTranscriberScheduler()
        let transcriber = makeTranscriber(transport: transport, scheduler: scheduler)

        try await transcriber.connect(configuration: configuration)

        #expect(await transcriber.state == .live)
        #expect(await transport.connectionAttempts == 1)

        do {
            try await transcriber.connect(configuration: configuration)
            Issue.record("Expected duplicate connect to fail")
        } catch {
            #expect(error as? TencentLiveTranscriberError == .alreadyConnected)
        }

        await transcriber.cancel()
    }

    @Test("16k PCM 按 6400 字节和 200ms 实时节奏发送")
    func sendsTwoHundredMillisecondPCMFrames() async throws {
        let connection = FakeTencentWebSocketConnection()
        let transport = FakeTencentWebSocketTransport([.connection(connection)])
        let scheduler = FakeTencentTranscriberScheduler()
        let transcriber = makeTranscriber(transport: transport, scheduler: scheduler)
        try await transcriber.connect(configuration: configuration)

        try await transcriber.send(Data(repeating: 1, count: 3_200))
        #expect(await connection.sentMessages.isEmpty)

        try await transcriber.send(Data(repeating: 2, count: 9_600))

        let messages = await connection.sentMessages
        #expect(messages.count == 2)
        #expect(messages.allSatisfy { message in
            guard case let .data(data) = message else { return false }
            return data.count == 6_400
        })
        #expect(messages.first == .data(
            Data(repeating: 1, count: 3_200) + Data(repeating: 2, count: 3_200)
        ))
        #expect(messages.last == .data(Data(repeating: 2, count: 6_400)))
        #expect(await scheduler.recordedSleeps == [200_000_000])

        await transcriber.cancel()
    }

    @Test("响应通过唯一事件流产生统一字幕事件")
    func emitsDecodedTranscriptEvents() async throws {
        let connection = FakeTencentWebSocketConnection()
        let transport = FakeTencentWebSocketTransport([.connection(connection)])
        let scheduler = FakeTencentTranscriberScheduler()
        let transcriber = makeTranscriber(transport: transport, scheduler: scheduler)
        try await transcriber.connect(configuration: configuration)
        var iterator = transcriber.events().makeAsyncIterator()

        await connection.enqueue(.text(
            #"{"code":0,"sentences":{"sentence_list":[{"sentence":"测试字幕","sentence_type":1,"sentence_id":4,"speaker_id":2,"start_time":100,"end_time":500}]}}"#
        ))

        let event = try await iterator.next()
        #expect(event == .confirmed(
            id: "4",
            speakerID: "2",
            text: "测试字幕",
            startMS: 100,
            endMS: 500
        ))
        await transcriber.cancel()
    }

    @Test("finish 刷新尾包、发送 end 文本并等待服务端 final")
    func finishesNormally() async throws {
        let connection = FakeTencentWebSocketConnection()
        let transport = FakeTencentWebSocketTransport([.connection(connection)])
        let scheduler = FakeTencentTranscriberScheduler()
        let transcriber = makeTranscriber(transport: transport, scheduler: scheduler)
        try await transcriber.connect(configuration: configuration)
        try await transcriber.send(Data(repeating: 7, count: 100))

        let terminal = Task {
            var iterator = transcriber.events().makeAsyncIterator()
            return try await iterator.next()
        }
        await transcriber.finish()

        #expect(await connection.sentMessages == [
            .data(Data(repeating: 7, count: 100)),
            .text(#"{"type":"end"}"#),
        ])
        do {
            try await transcriber.send(Data([1]))
            Issue.record("Expected send after finish to fail")
        } catch {
            #expect(error as? TencentLiveTranscriberError == .finished)
        }

        await connection.enqueue(.text(#"{"code":0,"final":1}"#))
        #expect(try await terminal.value == nil)
        #expect(await transcriber.state == .finished)
    }

    @Test("服务端错误终止事件流且不暴露响应内容")
    func handlesRedactedServiceError() async throws {
        let connection = FakeTencentWebSocketConnection()
        let transport = FakeTencentWebSocketTransport([.connection(connection)])
        let scheduler = FakeTencentTranscriberScheduler()
        let transcriber = makeTranscriber(transport: transport, scheduler: scheduler)
        try await transcriber.connect(configuration: configuration)
        let terminal = nextEventResult(from: transcriber)

        await connection.enqueue(.text(
            #"{"code":4002,"message":"credential-marker","sentences":{"sentence_list":[{"sentence":"transcript-marker","sentence_type":1,"sentence_id":1,"speaker_id":0,"start_time":0,"end_time":1}]}}"#
        ))

        switch await terminal.value {
        case .success:
            Issue.record("Expected service error")
        case let .failure(error):
            #expect(error as? TencentTranscriptDecoderError == .service(code: 4_002))
            #expect(!String(describing: error).contains("credential-marker"))
            #expect(!String(describing: error).contains("transcript-marker"))
        }
        #expect(await transcriber.state == .failed)
        #expect(await scheduler.recordedSleeps.isEmpty)
    }

    @Test("取消关闭连接、干净结束事件流并拒绝后续发送")
    func cancelsCleanly() async throws {
        let connection = FakeTencentWebSocketConnection()
        let transport = FakeTencentWebSocketTransport([.connection(connection)])
        let scheduler = FakeTencentTranscriberScheduler()
        let transcriber = makeTranscriber(transport: transport, scheduler: scheduler)
        try await transcriber.connect(configuration: configuration)
        let terminal = nextEventResult(from: transcriber)

        await transcriber.cancel()

        switch await terminal.value {
        case let .success(event):
            #expect(event == nil)
        case .failure:
            Issue.record("Expected clean event-stream completion")
        }
        #expect(await transcriber.state == .finished)
        #expect(await connection.wasCancelled)
        do {
            try await transcriber.send(Data([1]))
            Issue.record("Expected send after cancel to fail")
        } catch {
            #expect(error as? TencentLiveTranscriberError == .finished)
        }
    }

    @Test("传输中断后用新 voice ID 重连并继续产生事件")
    func reconnectsWithFreshVoiceID() async throws {
        let first = FakeTencentWebSocketConnection()
        let second = FakeTencentWebSocketConnection()
        let transport = FakeTencentWebSocketTransport([
            .connection(first),
            .connection(second),
        ])
        let scheduler = FakeTencentTranscriberScheduler()
        let transcriber = makeTranscriber(transport: transport, scheduler: scheduler)
        try await transcriber.connect(configuration: configuration)
        let eventTask = nextEventResult(from: transcriber)

        await first.failInbound()
        await second.enqueue(.text(
            #"{"code":0,"sentences":{"sentence_list":[{"sentence":"恢复","sentence_type":0,"sentence_id":0,"speaker_id":-1,"start_time":0,"end_time":200}]}}"#
        ))

        switch await eventTask.value {
        case let .success(event):
            #expect(event == .partial(
                id: "0",
                speakerID: nil,
                text: "恢复",
                startMS: 0,
                endMS: 200
            ))
        case .failure:
            Issue.record("Expected an event after reconnect")
        }
        #expect(await scheduler.recordedSleeps == [200_000_000])
        #expect(await transport.connectedVoiceIDs == ["initial-voice", "retry-voice-1"])
        #expect(await transcriber.state == .live)

        await transcriber.cancel()
    }

    @Test("最多进行三次有界指数退避重连")
    func stopsAfterThreeReconnectAttempts() async throws {
        let first = FakeTencentWebSocketConnection()
        let transport = FakeTencentWebSocketTransport([
            .connection(first),
            .failure,
            .failure,
            .failure,
        ])
        let scheduler = FakeTencentTranscriberScheduler()
        let transcriber = makeTranscriber(transport: transport, scheduler: scheduler)
        try await transcriber.connect(configuration: configuration)
        let terminal = nextEventResult(from: transcriber)

        await first.failInbound()

        switch await terminal.value {
        case .success:
            Issue.record("Expected reconnect exhaustion")
        case let .failure(error):
            #expect(error as? TencentLiveTranscriberError == .reconnectLimitExceeded)
        }
        #expect(await scheduler.recordedSleeps == [
            200_000_000,
            400_000_000,
            800_000_000,
        ])
        #expect(await transport.connectionAttempts == 4)
        #expect(await transport.connectedVoiceIDs == [
            "initial-voice",
            "retry-voice-1",
            "retry-voice-2",
            "retry-voice-3",
        ])
        #expect(await transcriber.state == .failed)
    }
}

private extension TencentLiveTranscriberTests {
    static let configuration = ASRConfiguration(
        appID: "1250000000",
        secretID: "AKIDEXAMPLE",
        secretKey: "test-secret",
        voiceID: "initial-voice"
    )

    func makeTranscriber(
        transport: FakeTencentWebSocketTransport,
        scheduler: FakeTencentTranscriberScheduler
    ) -> TencentLiveTranscriber {
        let retryVoiceIDs = LockedValues([
            "retry-voice-1",
            "retry-voice-2",
            "retry-voice-3",
        ])
        return TencentLiveTranscriber(
            transport: transport,
            signer: TencentSigner(),
            decoder: TencentTranscriptDecoder(),
            scheduler: scheduler,
            timestamp: { 1_700_000_000 },
            nonce: { 123_456 },
            voiceID: { retryVoiceIDs.removeFirst() }
        )
    }

    func nextEventResult(
        from transcriber: TencentLiveTranscriber
    ) -> Task<Result<TranscriptEvent?, Error>, Never> {
        Task {
            var iterator = transcriber.events().makeAsyncIterator()
            do {
                return .success(try await iterator.next())
            } catch {
                return .failure(error)
            }
        }
    }
}

private enum FakeTencentTransportError: Error {
    case unavailable
}

private actor FakeTencentWebSocketConnection: TencentWebSocketConnection {
    private var queuedInbound: [TencentWebSocketMessage] = []
    private var inboundWaiter: CheckedContinuation<Result<TencentWebSocketMessage, Error>, Never>?
    private var inboundFailed = false
    private(set) var sentMessages: [TencentWebSocketMessage] = []
    private(set) var wasCancelled = false

    func send(_ message: TencentWebSocketMessage) async throws {
        guard !wasCancelled else { throw FakeTencentTransportError.unavailable }
        sentMessages.append(message)
    }

    func receive() async throws -> TencentWebSocketMessage {
        guard !inboundFailed else { throw FakeTencentTransportError.unavailable }
        if !queuedInbound.isEmpty {
            return queuedInbound.removeFirst()
        }
        let result: Result<TencentWebSocketMessage, Error> = await withCheckedContinuation { continuation in
            inboundWaiter = continuation
        }
        return try result.get()
    }

    func cancel() async {
        wasCancelled = true
        inboundFailed = true
        inboundWaiter?.resume(returning: .failure(FakeTencentTransportError.unavailable))
        inboundWaiter = nil
    }

    func enqueue(_ message: TencentWebSocketMessage) {
        if let inboundWaiter {
            self.inboundWaiter = nil
            inboundWaiter.resume(returning: .success(message))
        } else {
            queuedInbound.append(message)
        }
    }

    func failInbound() {
        inboundFailed = true
        if let inboundWaiter {
            self.inboundWaiter = nil
            inboundWaiter.resume(returning: .failure(FakeTencentTransportError.unavailable))
        }
    }
}

private actor FakeTencentWebSocketTransport: TencentWebSocketTransport {
    enum Plan: Sendable {
        case connection(FakeTencentWebSocketConnection)
        case failure
    }

    private var plans: [Plan]
    private(set) var connectionAttempts = 0
    private(set) var connectedVoiceIDs: [String] = []

    init(_ plans: [Plan]) {
        self.plans = plans
    }

    func connect(to url: URL) async throws -> any TencentWebSocketConnection {
        connectionAttempts += 1
        let voiceID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "voice_id" })?
            .value
        connectedVoiceIDs.append(voiceID ?? "missing")

        guard !plans.isEmpty else { throw FakeTencentTransportError.unavailable }
        switch plans.removeFirst() {
        case let .connection(connection):
            return connection
        case .failure:
            throw FakeTencentTransportError.unavailable
        }
    }
}

private actor FakeTencentTranscriberScheduler: TencentTranscriberScheduler {
    private(set) var recordedSleeps: [UInt64] = []
    private var now: UInt64 = 1_000_000_000

    func nowNanoseconds() async -> UInt64 {
        now
    }

    func sleep(nanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        recordedSleeps.append(nanoseconds)
        now += nanoseconds
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value]

    init(_ values: [Value]) {
        self.values = values
    }

    func removeFirst() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return values.removeFirst()
    }
}
