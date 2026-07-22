import Foundation
import Testing
@testable import CallCapture

@Suite("TencentLiveTranscriber")
struct TencentLiveTranscriberTests {
    @Test("connect 等待腾讯 code=0 确认且保留重叠的首个字幕事件")
    func waitsForApplicationHandshake() async throws {
        let connection = FakeTencentWebSocketConnection(initialInbound: [])
        let transport = FakeTencentWebSocketTransport([.connection(connection)])
        let scheduler = FakeTencentTranscriberScheduler()
        let transcriber = makeTranscriber(transport: transport, scheduler: scheduler)
        let connectTask = Task<Result<Void, Error>, Never> {
            do {
                try await transcriber.connect(configuration: configuration)
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        try await waitUntil { await connection.hasPendingReceive }
        #expect(await transcriber.state == .connecting)
        do {
            try await transcriber.send(Data(repeating: 1, count: 6_400))
            Issue.record("Expected send before authentication to fail")
        } catch {
            #expect(error as? TencentLiveTranscriberError == .notConnected)
        }
        #expect(await connection.sentMessages.isEmpty)

        await connection.enqueue(.text(
            #"{"code":0,"message":"success","sentences":{"sentence_list":[{"sentence":"首帧字幕","sentence_type":0,"sentence_id":0,"speaker_id":-1,"start_time":0,"end_time":200}]}}"#
        ))
        switch await connectTask.value {
        case .success:
            break
        case .failure:
            Issue.record("Expected code=0 handshake to connect")
        }

        var iterator = transcriber.events().makeAsyncIterator()
        #expect(try await iterator.next() == .partial(
            id: "1:0",
            speakerID: nil,
            text: "首帧字幕",
            startMS: 0,
            endMS: 200
        ))
        #expect(await transcriber.state == .live)
        await transcriber.cancel()
    }

    @Test("腾讯鉴权错误使 connect 失败且不发送音频")
    func rejectsFailedApplicationHandshake() async {
        let connection = FakeTencentWebSocketConnection(initialInbound: [.text(
            #"{"code":4002,"message":"credential-marker"}"#
        )])
        let transport = FakeTencentWebSocketTransport([.connection(connection)])
        let scheduler = FakeTencentTranscriberScheduler()
        let transcriber = makeTranscriber(transport: transport, scheduler: scheduler)

        do {
            try await transcriber.connect(configuration: configuration)
            Issue.record("Expected authentication failure")
        } catch {
            #expect(error as? TencentTranscriptDecoderError == .service(code: 4_002))
            #expect(!String(describing: error).contains("credential-marker"))
        }
        #expect(await transcriber.state == .failed)
        #expect(await connection.sentMessages.isEmpty)
    }

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
            id: "1:4",
            speakerID: "1:2",
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

    @Test("end 发送与接收同时失败时保持 failed 终态")
    func preservesFailureDuringEndRace() async throws {
        let connection = FakeTencentWebSocketConnection()
        let transport = FakeTencentWebSocketTransport([.connection(connection)])
        let scheduler = FakeTencentTranscriberScheduler()
        let transcriber = makeTranscriber(transport: transport, scheduler: scheduler)
        try await transcriber.connect(configuration: configuration)
        await connection.blockNextEndSend()
        let terminal = nextEventResult(from: transcriber)
        let finishTask = Task { await transcriber.finish() }

        try await waitUntil { await connection.hasBlockedSend }
        await connection.failInbound()
        await finishTask.value

        switch await terminal.value {
        case .success:
            Issue.record("Expected terminal connection failure")
        case let .failure(error):
            #expect(error as? TencentLiveTranscriberError == .connectionFailed)
        }
        #expect(await transcriber.state == .failed)
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
                id: "2:0",
                speakerID: nil,
                text: "恢复",
                startMS: 200,
                endMS: 400
            ))
        case .failure:
            Issue.record("Expected an event after reconnect")
        }
        #expect(await scheduler.recordedSleeps == [200_000_000])
        #expect(await transport.connectedVoiceIDs == ["initial-voice", "retry-voice-1"])
        #expect(await transcriber.state == .live)

        await transcriber.cancel()
    }

    @Test("重连后相同句子与说话人 ID 使用新代命名空间并延续会议时间线")
    @MainActor func namespacesReconnectIdentityAndTimeline() async throws {
        let first = FakeTencentWebSocketConnection(initialInbound: [.text(
            #"{"code":0,"sentences":{"sentence_list":[{"sentence":"旧连接","sentence_type":1,"sentence_id":0,"speaker_id":1,"start_time":100,"end_time":200}]}}"#
        )])
        let second = FakeTencentWebSocketConnection(initialInbound: [.text(
            #"{"code":0,"sentences":{"sentence_list":[{"sentence":"新连接临时","sentence_type":0,"sentence_id":0,"speaker_id":1,"start_time":0,"end_time":100}]}}"#
        )])
        let transport = FakeTencentWebSocketTransport([
            .connection(first),
            .connection(second),
        ])
        let scheduler = FakeTencentTranscriberScheduler()
        let transcriber = makeTranscriber(transport: transport, scheduler: scheduler)
        try await transcriber.connect(configuration: configuration)
        var iterator = transcriber.events().makeAsyncIterator()

        let oldFinal = try #require(try await iterator.next())
        await first.failInbound()
        let newPartial = try #require(try await iterator.next())
        await second.enqueue(.text(
            #"{"code":0,"sentences":{"sentence_list":[{"sentence":"新连接最终","sentence_type":1,"sentence_id":0,"speaker_id":1,"start_time":0,"end_time":150}]}}"#
        ))
        let newFinal = try #require(try await iterator.next())

        #expect(oldFinal == .confirmed(
            id: "1:0",
            speakerID: "1:1",
            text: "旧连接",
            startMS: 100,
            endMS: 200
        ))
        #expect(newPartial == .partial(
            id: "2:0",
            speakerID: "2:1",
            text: "新连接临时",
            startMS: 200,
            endMS: 300
        ))
        #expect(newFinal == .confirmed(
            id: "2:0",
            speakerID: "2:1",
            text: "新连接最终",
            startMS: 200,
            endMS: 350
        ))

        let store = LiveTranscriptStore()
        store.apply(oldFinal)
        store.apply(newPartial)
        store.apply(newFinal)
        #expect(store.confirmedUtterances.map(\.text) == ["旧连接", "新连接最终"])
        #expect(store.confirmedUtterances.map(\.startMS) == [100, 200])
        #expect(store.confirmedUtterances.map(\.speakerLabel) == ["发言人 1", "发言人 2"])
        #expect(store.partialUtterance == nil)
        await transcriber.cancel()
    }

    @Test("重连鉴权失败会计入退避并尝试下一条新连接")
    func retriesARejectedReconnectHandshake() async throws {
        let first = FakeTencentWebSocketConnection()
        let rejected = FakeTencentWebSocketConnection(initialInbound: [
            .text(#"{"code":4002,"message":"redacted"}"#),
        ])
        let recovered = FakeTencentWebSocketConnection()
        let transport = FakeTencentWebSocketTransport([
            .connection(first),
            .connection(rejected),
            .connection(recovered),
        ])
        let scheduler = FakeTencentTranscriberScheduler()
        let transcriber = makeTranscriber(transport: transport, scheduler: scheduler)
        try await transcriber.connect(configuration: configuration)
        let eventTask = nextEventResult(from: transcriber)

        await first.failInbound()
        await recovered.enqueue(.text(
            #"{"code":0,"sentences":{"sentence_list":[{"sentence":"恢复","sentence_type":1,"sentence_id":2,"speaker_id":1,"start_time":200,"end_time":400}]}}"#
        ))

        switch await eventTask.value {
        case let .success(event):
            #expect(event == .confirmed(
                id: "2:2",
                speakerID: "2:1",
                text: "恢复",
                startMS: 800,
                endMS: 1_000
            ))
        case .failure:
            Issue.record("Expected recovery after rejected handshake")
        }
        #expect(await transport.connectionAttempts == 3)
        #expect(await scheduler.recordedSleeps == [200_000_000, 400_000_000])
        #expect(await transcriber.state == .live)
        await transcriber.cancel()
    }

    @Test("长时间断线后旧 PCM 不会被平移进新连接的 30 秒上下文")
    @MainActor
    func excludesStalePCMFromRecentContextAfterLongReconnect() async throws {
        let first = FakeTencentWebSocketConnection(
            initialInbound: [.text(
                #"{"code":0,"message":"success","sentences":{"sentence_list":[{"sentence":"旧内容","sentence_type":1,"sentence_id":0,"speaker_id":1,"start_time":0,"end_time":200}]}}"#
            )],
            cancelCompletesBlockedSend: false
        )
        let second = FakeTencentWebSocketConnection()
        let transport = FakeTencentWebSocketTransport([
            .connection(first),
            .connection(second),
        ])
        let scheduler = FakeTencentTranscriberScheduler()
        let transcriber = makeTranscriber(transport: transport, scheduler: scheduler)
        try await transcriber.connect(configuration: configuration)
        var events = transcriber.events().makeAsyncIterator()
        let oldEvent = try #require(try await events.next())
        await first.blockNextDataSend()
        let staleFrame = Data(repeating: 9, count: 6_400)
        let freshFrame = Data(repeating: 7, count: 6_400)
        let sendTask = Task { try await transcriber.send(staleFrame) }

        try await waitUntil { await first.hasBlockedSend }
        await scheduler.advance(nanoseconds: 40_000_000_000)
        await first.failInbound()
        try await waitUntil {
            let attempts = await transport.connectionAttempts
            let state = await transcriber.state
            return attempts == 2 && state == .live
        }
        await first.completeBlockedSendSuccessfully()
        let sendResult = try await sendTask.value
        guard case let .reconnectDiscardRequired(sequence, discardedChunkCount) = sendResult else {
            Issue.record("Expected a reconnect discard barrier")
            await transcriber.cancel()
            return
        }
        #expect(discardedChunkCount == 0)
        #expect(await transcriber.acknowledgeReconnectDiscard(sequence: sequence) == 0)
        try await transcriber.send(freshFrame)
        await second.enqueue(.text(
            #"{"code":0,"sentences":{"sentence_list":[{"sentence":"新内容","sentence_type":1,"sentence_id":0,"speaker_id":1,"start_time":0,"end_time":200}]}}"#
        ))
        let freshEvent = try #require(try await events.next())

        #expect(await first.sentMessages == [.data(staleFrame)])
        #expect(await second.sentMessages == [.data(freshFrame)])

        let store = LiveTranscriptStore()
        store.apply(oldEvent)
        store.apply(freshEvent)
        #expect(store.context(endingAt: 40.4, duration: 30).map(\.text) == ["新内容"])
        await transcriber.cancel()
    }

    @Test("重连会丢弃供应商内部尚未成帧的 PCM 并报告降级")
    func discardsProviderPendingPCMOnReconnect() async throws {
        let first = FakeTencentWebSocketConnection()
        let second = FakeTencentWebSocketConnection()
        let transport = FakeTencentWebSocketTransport([
            .connection(first),
            .connection(second),
        ])
        let transcriber = makeTranscriber(
            transport: transport,
            scheduler: FakeTencentTranscriberScheduler()
        )
        try await transcriber.connect(configuration: configuration)
        try await transcriber.send(Data(repeating: 3, count: 3_200))

        await first.failInbound()
        try await waitUntil {
            let attempts = await transport.connectionAttempts
            let state = await transcriber.state
            return attempts == 2 && state == .live
        }

        guard let discardStatus = await transcriber.reconnectDiscardStatus(),
              case let .reconnectDiscardRequired(sequence, discardedChunkCount) =
              discardStatus
        else {
            Issue.record("Expected pending PCM to create a reconnect discard barrier")
            await transcriber.cancel()
            return
        }
        #expect(discardedChunkCount == 1)
        #expect(await transcriber.acknowledgeReconnectDiscard(sequence: sequence) == 1)
        #expect(await second.sentMessages.isEmpty)

        let freshFrame = Data(repeating: 4, count: 6_400)
        try await transcriber.send(freshFrame)
        #expect(await second.sentMessages == [.data(freshFrame)])
        await transcriber.cancel()
    }

    @Test("非整除回调块跨帧消费后只计未发送的源块")
    func countsOnlyUnsentSourceChunksAcrossFrameBoundaries() async throws {
        let first = FakeTencentWebSocketConnection(cancelCompletesBlockedSend: false)
        let second = FakeTencentWebSocketConnection()
        let transport = FakeTencentWebSocketTransport([
            .connection(first),
            .connection(second),
        ])
        let transcriber = makeTranscriber(
            transport: transport,
            scheduler: FakeTencentTranscriberScheduler()
        )
        try await transcriber.connect(configuration: configuration)

        try await transcriber.send(Data(repeating: 1, count: 9_000))
        await first.blockNextDataSend()
        let sendTask = Task {
            try await transcriber.send(Data(repeating: 2, count: 5_400))
        }
        try await waitUntil { await first.hasBlockedSend }

        await first.failInbound()
        try await waitUntil {
            let attempts = await transport.connectionAttempts
            let state = await transcriber.state
            return attempts == 2 && state == .live
        }
        await first.completeBlockedSendSuccessfully()

        guard case let .reconnectDiscardRequired(sequence, discardedChunkCount) =
            try await sendTask.value
        else {
            Issue.record("Expected a reconnect discard barrier")
            await transcriber.cancel()
            return
        }
        #expect(discardedChunkCount == 1)
        #expect(await transcriber.acknowledgeReconnectDiscard(sequence: sequence) == 1)
        #expect(await first.sentMessages.count == 2)
        #expect(await second.sentMessages.isEmpty)
        await transcriber.cancel()
    }

    @Test("重连鉴权期间取消会关闭候选连接且不继续重试")
    func cancelsDuringReconnectAuthentication() async throws {
        let first = FakeTencentWebSocketConnection()
        let second = FakeTencentWebSocketConnection(initialInbound: [])
        let transport = FakeTencentWebSocketTransport([
            .connection(first),
            .connection(second),
            .failure,
            .failure,
        ])
        let scheduler = FakeTencentTranscriberScheduler()
        let transcriber = makeTranscriber(transport: transport, scheduler: scheduler)
        try await transcriber.connect(configuration: configuration)
        let terminal = nextEventResult(from: transcriber)

        await first.failInbound()
        try await waitUntil { await second.hasPendingReceive }
        #expect(await transcriber.state == .reconnecting)
        await transcriber.cancel()

        switch await terminal.value {
        case let .success(event):
            #expect(event == nil)
        case .failure:
            Issue.record("Expected clean cancellation")
        }
        #expect(await transcriber.state == .finished)
        #expect(await second.wasCancelled)
        #expect(await transport.connectionAttempts == 2)
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

    func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<10_000 {
            if await predicate() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for deterministic test condition")
        throw FakeTencentTransportError.unavailable
    }
}

private enum FakeTencentTransportError: Error {
    case unavailable
}

private actor FakeTencentWebSocketConnection: TencentWebSocketConnection {
    private var queuedInbound: [TencentWebSocketMessage] = []
    private var inboundWaiter: CheckedContinuation<Result<TencentWebSocketMessage, Error>, Never>?
    private var inboundFailed = false
    private var blockedSendKind: BlockedSendKind?
    private var blockedSendWaiter: CheckedContinuation<Result<Void, Error>, Never>?
    private let cancelCompletesBlockedSend: Bool
    private(set) var sentMessages: [TencentWebSocketMessage] = []
    private(set) var wasCancelled = false

    enum BlockedSendKind {
        case data
        case end
    }

    init(
        initialInbound: [TencentWebSocketMessage] = [
            .text(#"{"code":0,"message":"success"}"#),
        ],
        cancelCompletesBlockedSend: Bool = true
    ) {
        queuedInbound = initialInbound
        self.cancelCompletesBlockedSend = cancelCompletesBlockedSend
    }

    var hasPendingReceive: Bool {
        inboundWaiter != nil
    }

    var hasBlockedSend: Bool {
        blockedSendWaiter != nil
    }

    func send(_ message: TencentWebSocketMessage) async throws {
        guard !wasCancelled else { throw FakeTencentTransportError.unavailable }
        if shouldBlock(message) {
            blockedSendKind = nil
            let result: Result<Void, Error> = await withCheckedContinuation { continuation in
                blockedSendWaiter = continuation
            }
            try result.get()
        }
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
        if cancelCompletesBlockedSend {
            blockedSendWaiter?.resume(returning: .failure(FakeTencentTransportError.unavailable))
            blockedSendWaiter = nil
        }
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

    func blockNextDataSend() {
        blockedSendKind = .data
    }

    func blockNextEndSend() {
        blockedSendKind = .end
    }

    func completeBlockedSendSuccessfully() {
        blockedSendWaiter?.resume(returning: .success(()))
        blockedSendWaiter = nil
    }

    private func shouldBlock(_ message: TencentWebSocketMessage) -> Bool {
        switch (blockedSendKind, message) {
        case (.data, .data(_)):
            true
        case (.end, .text(#"{"type":"end"}"#)):
            true
        default:
            false
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

    func advance(nanoseconds: UInt64) {
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
