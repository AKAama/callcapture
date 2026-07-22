import Dispatch
import Foundation

enum TencentLiveTranscriberError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case alreadyConnected
    case notConnected
    case finished
    case connectionFailed
    case reconnectLimitExceeded

    var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            "Tencent ASR is already connected."
        case .notConnected:
            "Tencent ASR is not connected."
        case .finished:
            "Tencent ASR has already finished."
        case .connectionFailed:
            "Tencent ASR connection failed."
        case .reconnectLimitExceeded:
            "Tencent ASR reconnect limit was exceeded."
        }
    }

    var description: String { errorDescription ?? "Tencent ASR transport error." }
}

enum TencentWebSocketMessage: Equatable, Sendable {
    case data(Data)
    case text(String)
}

/// A narrow WebSocket seam used by the live transcriber.
///
/// Production uses `URLSession`; deterministic tests inject an in-memory
/// transport because `URLProtocol` does not reliably intercept WebSocket tasks.
protocol TencentWebSocketConnection: Sendable {
    func send(_ message: TencentWebSocketMessage) async throws
    func receive() async throws -> TencentWebSocketMessage
    func cancel() async
}

protocol TencentWebSocketTransport: Sendable {
    func connect(to url: URL) async throws -> any TencentWebSocketConnection
}

protocol TencentTranscriberScheduler: Sendable {
    func nowNanoseconds() async -> UInt64
    func sleep(nanoseconds: UInt64) async throws
}

private struct URLSessionTencentWebSocketTransport: TencentWebSocketTransport, @unchecked Sendable {
    let session: URLSession

    func connect(to url: URL) async throws -> any TencentWebSocketConnection {
        let task = session.webSocketTask(with: url)
        task.resume()
        return URLSessionTencentWebSocketConnection(task: task)
    }
}

private final class URLSessionTencentWebSocketConnection: TencentWebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ message: TencentWebSocketMessage) async throws {
        switch message {
        case let .data(data):
            try await task.send(.data(data))
        case let .text(text):
            try await task.send(.string(text))
        }
    }

    func receive() async throws -> TencentWebSocketMessage {
        switch try await task.receive() {
        case let .data(data):
            return .data(data)
        case let .string(text):
            return .text(text)
        @unknown default:
            throw TencentLiveTranscriberError.connectionFailed
        }
    }

    func cancel() async {
        task.cancel(with: .goingAway, reason: nil)
    }
}

private struct SystemTencentTranscriberScheduler: TencentTranscriberScheduler {
    func nowNanoseconds() async -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func sleep(nanoseconds: UInt64) async throws {
        try await Task<Never, Never>.sleep(nanoseconds: nanoseconds)
    }
}

/// Tencent speaker-mode real-time ASR connection.
///
/// The actor owns one event stream and one connection state machine. It never
/// logs request URLs, credentials, audio frames, service JSON, or transcript
/// text. Transport failures exposed to callers are deliberately fixed errors.
actor TencentLiveTranscriber: LiveTranscriber, LiveTranscriberConnectionStateReporting {
    private struct ReconnectDiscard {
        let sequence: Int
        var sourceChunkRemainingByteCounts: [Int]
    }

    enum State: Equatable, Sendable {
        case idle
        case connecting
        case live
        case reconnecting
        case finished
        case failed
    }

    private static let pcmBytesPerTwoHundredMilliseconds = 6_400
    private static let frameIntervalNanoseconds: UInt64 = 200_000_000
    private static let maximumReconnectAttempts = 3
    private static let endMessage = #"{"type":"end"}"#

    private let transport: any TencentWebSocketTransport
    private let signer: TencentSigner
    private let decoder: TencentTranscriptDecoder
    private let scheduler: any TencentTranscriberScheduler
    private let timestamp: @Sendable () -> Int
    private let nonce: @Sendable () -> Int
    private let voiceID: @Sendable () -> String
    private let eventContinuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    nonisolated let eventStream: AsyncThrowingStream<TranscriptEvent, Error>
    private let connectionStateContinuation: AsyncStream<LiveTranscriberConnectionState>.Continuation
    nonisolated let connectionStateStream: AsyncStream<LiveTranscriberConnectionState>

    private(set) var state: State = .idle {
        didSet {
            connectionStateContinuation.yield(Self.connectionState(for: state))
        }
    }
    private var configuration: ASRConfiguration?
    private var connection: (any TencentWebSocketConnection)?
    private var authenticatingConnection: (any TencentWebSocketConnection)?
    private var connectionGeneration = 0
    private var sessionTimelineOriginNanoseconds: UInt64?
    private var connectionTimelineOffsetMS = 0
    private var latestTimelineEndMS = 0
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Bool, Never>?
    private var reconnectWaiters: [CheckedContinuation<Bool, Never>] = []
    private var receiveTask: Task<Void, Never>?
    private var pendingPCM = Data()
    private var pendingPCMSourceChunkByteCounts: [Int] = []
    private var reconnectDiscardSequence = 0
    private var pendingReconnectDiscard: ReconnectDiscard?
    private var lastAudioSendNanoseconds: UInt64?
    private var finishRequested = false
    private var streamTerminated = false
    private var isSending = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        session: URLSession = .shared,
        signer: TencentSigner = TencentSigner()
    ) {
        self.init(
            transport: URLSessionTencentWebSocketTransport(session: session),
            signer: signer,
            decoder: TencentTranscriptDecoder(),
            scheduler: SystemTencentTranscriberScheduler(),
            timestamp: { Int(Date().timeIntervalSince1970) },
            nonce: { Int.random(in: 1...Int(Int32.max)) },
            voiceID: { UUID().uuidString }
        )
    }

    init(
        transport: any TencentWebSocketTransport,
        signer: TencentSigner,
        decoder: TencentTranscriptDecoder,
        scheduler: any TencentTranscriberScheduler,
        timestamp: @escaping @Sendable () -> Int,
        nonce: @escaping @Sendable () -> Int,
        voiceID: @escaping @Sendable () -> String
    ) {
        let pair = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        eventStream = pair.stream
        eventContinuation = pair.continuation
        let statePair = AsyncStream<LiveTranscriberConnectionState>.makeStream()
        connectionStateStream = statePair.stream
        connectionStateContinuation = statePair.continuation
        self.transport = transport
        self.signer = signer
        self.decoder = decoder
        self.scheduler = scheduler
        self.timestamp = timestamp
        self.nonce = nonce
        self.voiceID = voiceID
    }

    func connect(configuration: ASRConfiguration) async throws {
        guard state == .idle else {
            if state == .finished { throw TencentLiveTranscriberError.finished }
            throw TencentLiveTranscriberError.alreadyConnected
        }

        state = .connecting
        self.configuration = configuration
        sessionTimelineOriginNanoseconds = await scheduler.nowNanoseconds()
        var candidate: (any TencentWebSocketConnection)?

        do {
            let url = try signedURL(configuration: configuration)
            let newConnection = try await transport.connect(to: url)
            candidate = newConnection
            guard state == .connecting else {
                await newConnection.cancel()
                throw TencentLiveTranscriberError.finished
            }

            authenticatingConnection = newConnection
            let handshake = try await authenticate(newConnection)
            guard state == .connecting else {
                authenticatingConnection = nil
                await newConnection.cancel()
                throw TencentLiveTranscriberError.finished
            }

            authenticatingConnection = nil
            let timelineOffsetMS = await nextConnectionTimelineOffsetMS()
            guard state == .connecting else {
                await newConnection.cancel()
                throw TencentLiveTranscriberError.finished
            }
            let nextGeneration = connectionGeneration + 1
            let handshakeEvents = try scope(
                handshake.events,
                generation: nextGeneration,
                timelineOffsetMS: timelineOffsetMS
            )
            connectionGeneration = nextGeneration
            connectionTimelineOffsetMS = timelineOffsetMS
            connection = newConnection
            state = .live
            yield(handshakeEvents)
            startReceiving(on: newConnection, generation: connectionGeneration)
        } catch {
            authenticatingConnection = nil
            await candidate?.cancel()
            if state == .finished {
                throw TencentLiveTranscriberError.finished
            }
            let safeError = sanitized(error)
            await fail(with: safeError)
            throw safeError
        }
    }

    func send(_ pcm: Data) async throws -> LiveTranscriberSendResult {
        await acquireSendSlot()
        defer { releaseSendSlot() }

        guard !finishRequested, state != .finished else {
            throw TencentLiveTranscriberError.finished
        }

        if state == .reconnecting {
            guard await waitForReconnectCompletion() else {
                throw errorForCurrentState()
            }
        }

        guard state == .live else { throw errorForCurrentState() }
        guard !pcm.isEmpty else { return .sent }
        if pendingReconnectDiscard != nil {
            addCurrentInputToReconnectDiscard(byteCount: pcm.count)
            return reconnectDiscardResult()
        }
        pendingPCM.append(pcm)
        pendingPCMSourceChunkByteCounts.append(pcm.count)

        while pendingPCM.count >= Self.pcmBytesPerTwoHundredMilliseconds {
            let frame = Data(pendingPCM.prefix(Self.pcmBytesPerTwoHundredMilliseconds))
            guard try await transmit(frame) else {
                return reconnectDiscardResult()
            }
            pendingPCM.removeFirst(Self.pcmBytesPerTwoHundredMilliseconds)
            consumeSourceBytes(
                Self.pcmBytesPerTwoHundredMilliseconds,
                from: &pendingPCMSourceChunkByteCounts
            )
        }
        return .sent
    }

    func reconnectDiscardStatus() -> LiveTranscriberSendResult? {
        guard pendingReconnectDiscard != nil else { return nil }
        return reconnectDiscardResult()
    }

    func acknowledgeReconnectDiscard(sequence: Int) -> Int {
        guard let discard = pendingReconnectDiscard,
              discard.sequence == sequence
        else { return 0 }
        pendingReconnectDiscard = nil
        return discard.sourceChunkRemainingByteCounts.count
    }

    nonisolated func events() -> AsyncThrowingStream<TranscriptEvent, Error> {
        eventStream
    }

    nonisolated func connectionStateUpdates() -> AsyncStream<LiveTranscriberConnectionState> {
        connectionStateStream
    }

    func finish() async {
        await acquireSendSlot()
        defer { releaseSendSlot() }

        guard state != .finished, state != .failed, !finishRequested else { return }

        guard state == .live || state == .reconnecting else {
            await completeImmediately()
            return
        }

        if state == .reconnecting {
            guard await waitForReconnectCompletion() else { return }
        }

        do {
            if !pendingPCM.isEmpty {
                let finalAudio = pendingPCM
                if try await transmit(finalAudio) {
                    pendingPCM.removeAll(keepingCapacity: false)
                    pendingPCMSourceChunkByteCounts.removeAll(keepingCapacity: false)
                }
            }

            finishRequested = true
            guard let connection else {
                await fail(with: TencentLiveTranscriberError.connectionFailed)
                return
            }
            try await connection.send(.text(Self.endMessage))
        } catch {
            if state != .finished {
                await fail(with: TencentLiveTranscriberError.connectionFailed)
            }
        }
    }

    func cancel() async {
        guard !streamTerminated else { return }
        finishRequested = true
        reconnectTask?.cancel()
        reconnectTask = nil
        resumeReconnectWaiters(with: false)
        receiveTask?.cancel()
        receiveTask = nil
        let connection = self.connection
        let authenticatingConnection = self.authenticatingConnection
        self.connection = nil
        self.authenticatingConnection = nil
        configuration = nil
        pendingPCM.removeAll(keepingCapacity: false)
        pendingPCMSourceChunkByteCounts.removeAll(keepingCapacity: false)
        state = .finished
        terminateEventStream()
        await connection?.cancel()
        await authenticatingConnection?.cancel()
    }
}

private extension TencentLiveTranscriber {
    static func connectionState(for state: State) -> LiveTranscriberConnectionState {
        switch state {
        case .idle: .idle
        case .connecting: .connecting
        case .live: .live
        case .reconnecting: .reconnecting
        case .finished: .finished
        case .failed: .failed
        }
    }

    struct CompletionEnvelope: Decodable {
        let final: Int?
    }

    struct DecodedServerFrame {
        let events: [TranscriptEvent]
        let isFinal: Bool
    }

    func signedURL(configuration: ASRConfiguration) throws -> URL {
        try signer.signedURL(
            configuration: configuration,
            timestamp: timestamp(),
            nonce: nonce()
        )
    }

    func configurationForReconnect() -> ASRConfiguration? {
        guard let configuration else { return nil }
        return ASRConfiguration(
            appID: configuration.appID,
            secretID: configuration.secretID,
            secretKey: configuration.secretKey,
            voiceID: voiceID(),
            engineModelType: configuration.engineModelType
        )
    }

    func authenticate(
        _ connection: any TencentWebSocketConnection
    ) async throws -> DecodedServerFrame {
        let frame = try decode(try await connection.receive())
        guard !frame.isFinal else {
            throw TencentTranscriptDecoderError.invalidResponse
        }
        return frame
    }

    func decode(_ message: TencentWebSocketMessage) throws -> DecodedServerFrame {
        let data: Data
        switch message {
        case let .data(receivedData):
            data = receivedData
        case let .text(text):
            data = Data(text.utf8)
        }

        let events = try decoder.decode(data)
        let completion: CompletionEnvelope
        do {
            completion = try JSONDecoder().decode(CompletionEnvelope.self, from: data)
        } catch {
            throw TencentTranscriptDecoderError.invalidResponse
        }
        guard completion.final == nil || completion.final == 0 || completion.final == 1 else {
            throw TencentTranscriptDecoderError.invalidResponse
        }
        return DecodedServerFrame(events: events, isFinal: completion.final == 1)
    }

    func nextConnectionTimelineOffsetMS() async -> Int {
        guard let origin = sessionTimelineOriginNanoseconds else {
            return latestTimelineEndMS
        }
        let now = await scheduler.nowNanoseconds()
        guard now >= origin else { return latestTimelineEndMS }
        let elapsedMilliseconds = (now - origin) / 1_000_000
        let boundedElapsed = elapsedMilliseconds > UInt64(Int.max)
            ? Int.max
            : Int(elapsedMilliseconds)
        return max(latestTimelineEndMS, boundedElapsed)
    }

    func yield(_ events: [TranscriptEvent]) {
        for event in events {
            switch event {
            case let .partial(_, _, _, _, endMS), let .confirmed(_, _, _, _, endMS):
                latestTimelineEndMS = max(latestTimelineEndMS, endMS)
            }
            eventContinuation.yield(event)
        }
    }

    func scope(
        _ events: [TranscriptEvent],
        generation: Int,
        timelineOffsetMS: Int
    ) throws -> [TranscriptEvent] {
        try events.map {
            try scope($0, generation: generation, timelineOffsetMS: timelineOffsetMS)
        }
    }

    func scope(
        _ event: TranscriptEvent,
        generation: Int,
        timelineOffsetMS: Int
    ) throws -> TranscriptEvent {
        func scopedID(_ id: String) -> String { "\(generation):\(id)" }
        func scopedSpeakerID(_ speakerID: String?) -> String? {
            speakerID.map { "\(generation):\($0)" }
        }
        func offset(_ value: Int) throws -> Int {
            let (result, overflow) = value.addingReportingOverflow(timelineOffsetMS)
            guard !overflow else { throw TencentTranscriptDecoderError.invalidResponse }
            return result
        }

        switch event {
        case let .partial(id, speakerID, text, startMS, endMS):
            return .partial(
                id: scopedID(id),
                speakerID: scopedSpeakerID(speakerID),
                text: text,
                startMS: try offset(startMS),
                endMS: try offset(endMS)
            )
        case let .confirmed(id, speakerID, text, startMS, endMS):
            return .confirmed(
                id: scopedID(id),
                speakerID: scopedSpeakerID(speakerID),
                text: text,
                startMS: try offset(startMS),
                endMS: try offset(endMS)
            )
        }
    }

    func sanitized(_ error: Error) -> Error {
        if let error = error as? TencentTranscriptDecoderError { return error }
        if let error = error as? TencentSignerError { return error }
        if let error = error as? TencentLiveTranscriberError { return error }
        return TencentLiveTranscriberError.connectionFailed
    }

    func startReceiving(
        on connection: any TencentWebSocketConnection,
        generation: Int
    ) {
        receiveTask = Task { [weak self] in
            await self?.receiveMessages(from: connection, generation: generation)
        }
    }

    func receiveMessages(
        from source: any TencentWebSocketConnection,
        generation: Int
    ) async {
        while !Task.isCancelled {
            let message: TencentWebSocketMessage
            do {
                message = try await source.receive()
            } catch {
                await connectionWasInterrupted(generation: generation)
                return
            }

            guard generation == connectionGeneration,
                  state == .live,
                  !Task.isCancelled
            else { return }

            do {
                let frame = try decode(message)
                let events = try scope(
                    frame.events,
                    generation: generation,
                    timelineOffsetMS: connectionTimelineOffsetMS
                )
                yield(events)
                if frame.isFinal {
                    await completeSuccessfully()
                    return
                }
            } catch let error as TencentTranscriptDecoderError {
                await fail(with: error)
                return
            } catch {
                await fail(with: TencentTranscriptDecoderError.invalidResponse)
                return
            }
        }
    }

    func connectionWasInterrupted(generation: Int) async {
        guard generation == connectionGeneration, state == .live else { return }
        if finishRequested {
            await fail(with: TencentLiveTranscriberError.connectionFailed)
            return
        }
        _ = await recover(from: generation)
    }

    func recover(from failedGeneration: Int) async -> Bool {
        if reconnectTask != nil {
            return await waitForReconnectCompletion()
        }

        guard state == .live,
              failedGeneration == connectionGeneration,
              !finishRequested
        else {
            return state == .live && !finishRequested
        }

        beginReconnectDiscard()
        state = .reconnecting
        lastAudioSendNanoseconds = nil
        let failedConnection = connection
        connection = nil
        let task = Task { [weak self] in
            guard let self else { return false }
            let succeeded = await self.performReconnects()
            await self.resumeReconnectWaiters(with: succeeded)
            return succeeded
        }
        reconnectTask = task
        await failedConnection?.cancel()
        return await waitForReconnectCompletion()
    }

    func performReconnects() async -> Bool {
        while reconnectAttempts < Self.maximumReconnectAttempts {
            reconnectAttempts += 1
            let delay = Self.frameIntervalNanoseconds << UInt64(reconnectAttempts - 1)

            do {
                try await scheduler.sleep(nanoseconds: delay)
            } catch {
                reconnectTask = nil
                return false
            }

            guard !Task.isCancelled,
                  state == .reconnecting,
                  let retryConfiguration = configurationForReconnect()
            else {
                reconnectTask = nil
                return false
            }

            var candidate: (any TencentWebSocketConnection)?
            do {
                let url = try signedURL(configuration: retryConfiguration)
                let newConnection = try await transport.connect(to: url)
                candidate = newConnection
                guard !Task.isCancelled, state == .reconnecting else {
                    await newConnection.cancel()
                    reconnectTask = nil
                    return false
                }

                authenticatingConnection = newConnection
                let handshake = try await authenticate(newConnection)
                guard !Task.isCancelled, state == .reconnecting else {
                    authenticatingConnection = nil
                    await newConnection.cancel()
                    reconnectTask = nil
                    return false
                }

                authenticatingConnection = nil
                let timelineOffsetMS = await nextConnectionTimelineOffsetMS()
                guard !Task.isCancelled, state == .reconnecting else {
                    await newConnection.cancel()
                    reconnectTask = nil
                    return false
                }
                let nextGeneration = connectionGeneration + 1
                let handshakeEvents = try scope(
                    handshake.events,
                    generation: nextGeneration,
                    timelineOffsetMS: timelineOffsetMS
                )
                connectionGeneration = nextGeneration
                connectionTimelineOffsetMS = timelineOffsetMS
                connection = newConnection
                state = .live
                reconnectTask = nil
                yield(handshakeEvents)
                startReceiving(on: newConnection, generation: connectionGeneration)
                return true
            } catch {
                authenticatingConnection = nil
                await candidate?.cancel()
                guard !Task.isCancelled, state == .reconnecting else {
                    reconnectTask = nil
                    return false
                }
                continue
            }
        }

        reconnectTask = nil
        await fail(with: TencentLiveTranscriberError.reconnectLimitExceeded)
        return false
    }

    func transmit(_ frame: Data) async throws -> Bool {
        guard !finishRequested, state != .finished else {
            throw TencentLiveTranscriberError.finished
        }
        if state == .reconnecting {
            guard await waitForReconnectCompletion() else {
                throw errorForCurrentState()
            }
            return false
        }
        guard state == .live, let connection else {
            throw errorForCurrentState()
        }

        let generation = connectionGeneration
        do {
            try await paceNextAudioFrame()
            guard generation == connectionGeneration,
                  state == .live,
                  self.connection != nil
            else { return false }
            try await connection.send(.data(frame))
            guard generation == connectionGeneration,
                  state == .live,
                  self.connection != nil
            else {
                reconcileLateSuccessfulSend(byteCount: frame.count)
                return false
            }
            let sentAt = await scheduler.nowNanoseconds()
            guard generation == connectionGeneration,
                  state == .live,
                  self.connection != nil
            else {
                reconcileLateSuccessfulSend(byteCount: frame.count)
                return false
            }
            lastAudioSendNanoseconds = sentAt
            return true
        } catch is CancellationError {
            throw TencentLiveTranscriberError.connectionFailed
        } catch {
            guard await recover(from: generation) else {
                throw errorForCurrentState()
            }
            return false
        }
    }

    func beginReconnectDiscard() {
        reconnectDiscardSequence += 1
        let carriedChunks = pendingReconnectDiscard?
            .sourceChunkRemainingByteCounts ?? []
        pendingReconnectDiscard = ReconnectDiscard(
            sequence: reconnectDiscardSequence,
            sourceChunkRemainingByteCounts: carriedChunks
                + pendingPCMSourceChunkByteCounts
        )
        pendingPCM.removeAll(keepingCapacity: true)
        pendingPCMSourceChunkByteCounts.removeAll(keepingCapacity: true)
    }

    func addCurrentInputToReconnectDiscard(byteCount: Int) {
        guard var discard = pendingReconnectDiscard else { return }
        discard.sourceChunkRemainingByteCounts.append(byteCount)
        pendingReconnectDiscard = discard
    }

    func reconcileLateSuccessfulSend(byteCount: Int) {
        guard var discard = pendingReconnectDiscard else { return }
        consumeSourceBytes(
            byteCount,
            from: &discard.sourceChunkRemainingByteCounts
        )
        pendingReconnectDiscard = discard
    }

    func consumeSourceBytes(_ byteCount: Int, from chunks: inout [Int]) {
        var remainingByteCount = byteCount
        while remainingByteCount > 0, !chunks.isEmpty {
            if chunks[0] <= remainingByteCount {
                remainingByteCount -= chunks.removeFirst()
            } else {
                chunks[0] -= remainingByteCount
                remainingByteCount = 0
            }
        }
    }

    func reconnectDiscardResult() -> LiveTranscriberSendResult {
        guard let discard = pendingReconnectDiscard else { return .sent }
        return .reconnectDiscardRequired(
            sequence: discard.sequence,
            discardedChunkCount: discard.sourceChunkRemainingByteCounts.count
        )
    }

    func waitForReconnectCompletion() async -> Bool {
        guard state == .reconnecting else {
            return state == .live && !finishRequested
        }
        return await withCheckedContinuation { continuation in
            reconnectWaiters.append(continuation)
        }
    }

    func resumeReconnectWaiters(with succeeded: Bool) {
        let waiters = reconnectWaiters
        reconnectWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: succeeded)
        }
    }

    func paceNextAudioFrame() async throws {
        guard let lastAudioSendNanoseconds else { return }
        let now = await scheduler.nowNanoseconds()
        let (deadline, overflow) = lastAudioSendNanoseconds.addingReportingOverflow(
            Self.frameIntervalNanoseconds
        )
        guard !overflow, now < deadline else { return }
        try await scheduler.sleep(nanoseconds: deadline - now)
    }

    func acquireSendSlot() async {
        if !isSending {
            isSending = true
            return
        }

        await withCheckedContinuation { continuation in
            sendWaiters.append(continuation)
        }
    }

    func releaseSendSlot() {
        if sendWaiters.isEmpty {
            isSending = false
        } else {
            sendWaiters.removeFirst().resume()
        }
    }

    func completeImmediately() async {
        guard !streamTerminated else { return }
        finishRequested = true
        reconnectTask?.cancel()
        reconnectTask = nil
        resumeReconnectWaiters(with: false)
        receiveTask?.cancel()
        receiveTask = nil
        let connection = self.connection
        let authenticatingConnection = self.authenticatingConnection
        self.connection = nil
        self.authenticatingConnection = nil
        configuration = nil
        pendingPCM.removeAll(keepingCapacity: false)
        pendingPCMSourceChunkByteCounts.removeAll(keepingCapacity: false)
        state = .finished
        terminateEventStream()
        await connection?.cancel()
        await authenticatingConnection?.cancel()
    }

    func completeSuccessfully() async {
        guard state == .live, !streamTerminated else { return }
        finishRequested = true
        reconnectTask?.cancel()
        reconnectTask = nil
        resumeReconnectWaiters(with: false)
        receiveTask = nil
        let connection = self.connection
        let authenticatingConnection = self.authenticatingConnection
        self.connection = nil
        self.authenticatingConnection = nil
        configuration = nil
        pendingPCM.removeAll(keepingCapacity: false)
        pendingPCMSourceChunkByteCounts.removeAll(keepingCapacity: false)
        state = .finished
        terminateEventStream()
        await connection?.cancel()
        await authenticatingConnection?.cancel()
    }

    func fail(with error: Error) async {
        guard !streamTerminated else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        resumeReconnectWaiters(with: false)
        receiveTask?.cancel()
        receiveTask = nil
        let connection = self.connection
        let authenticatingConnection = self.authenticatingConnection
        self.connection = nil
        self.authenticatingConnection = nil
        configuration = nil
        pendingPCM.removeAll(keepingCapacity: false)
        pendingPCMSourceChunkByteCounts.removeAll(keepingCapacity: false)
        state = .failed
        terminateEventStream(throwing: error)
        await connection?.cancel()
        await authenticatingConnection?.cancel()
    }

    func terminateEventStream(throwing error: Error? = nil) {
        guard !streamTerminated else { return }
        streamTerminated = true
        if let error {
            eventContinuation.finish(throwing: error)
        } else {
            eventContinuation.finish()
        }
        connectionStateContinuation.finish()
    }

    func errorForCurrentState() -> TencentLiveTranscriberError {
        switch state {
        case .finished:
            .finished
        case .failed:
            .connectionFailed
        case .idle, .connecting, .reconnecting:
            .notConnected
        case .live:
            .connectionFailed
        }
    }
}
