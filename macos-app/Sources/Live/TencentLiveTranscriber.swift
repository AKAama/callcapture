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
actor TencentLiveTranscriber: LiveTranscriber {
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

    private(set) var state: State = .idle
    private var configuration: ASRConfiguration?
    private var connection: (any TencentWebSocketConnection)?
    private var connectionGeneration = 0
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Bool, Never>?
    private var receiveTask: Task<Void, Never>?
    private var pendingPCM = Data()
    private var lastAudioSendNanoseconds: UInt64?
    private var finishRequested = false
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

        do {
            let url = try signedURL(configuration: configuration)
            let newConnection = try await transport.connect(to: url)
            guard state == .connecting else {
                await newConnection.cancel()
                throw TencentLiveTranscriberError.finished
            }

            connectionGeneration += 1
            connection = newConnection
            state = .live
            startReceiving(on: newConnection, generation: connectionGeneration)
        } catch let error as TencentLiveTranscriberError where error == .finished {
            throw error
        } catch {
            if state == .finished {
                throw TencentLiveTranscriberError.finished
            }
            await fail(with: TencentLiveTranscriberError.connectionFailed)
            throw TencentLiveTranscriberError.connectionFailed
        }
    }

    func send(_ pcm: Data) async throws {
        await acquireSendSlot()
        defer { releaseSendSlot() }

        guard !finishRequested, state != .finished else {
            throw TencentLiveTranscriberError.finished
        }

        if state == .reconnecting, let reconnectTask {
            guard await reconnectTask.value else {
                throw errorForCurrentState()
            }
        }

        guard state == .live else { throw errorForCurrentState() }
        guard !pcm.isEmpty else { return }
        pendingPCM.append(pcm)

        while pendingPCM.count >= Self.pcmBytesPerTwoHundredMilliseconds {
            let frame = Data(pendingPCM.prefix(Self.pcmBytesPerTwoHundredMilliseconds))
            try await transmit(frame)
            pendingPCM.removeFirst(Self.pcmBytesPerTwoHundredMilliseconds)
        }
    }

    nonisolated func events() -> AsyncThrowingStream<TranscriptEvent, Error> {
        eventStream
    }

    func finish() async {
        await acquireSendSlot()
        defer { releaseSendSlot() }

        guard state != .finished, state != .failed, !finishRequested else { return }

        guard state == .live || state == .reconnecting else {
            await completeImmediately()
            return
        }

        if state == .reconnecting, let reconnectTask {
            guard await reconnectTask.value else { return }
        }

        do {
            if !pendingPCM.isEmpty {
                let finalAudio = pendingPCM
                try await transmit(finalAudio)
                pendingPCM.removeAll(keepingCapacity: false)
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
        guard state != .finished, state != .failed else { return }
        finishRequested = true
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        let connection = self.connection
        self.connection = nil
        configuration = nil
        pendingPCM.removeAll(keepingCapacity: false)
        state = .finished
        eventContinuation.finish()
        await connection?.cancel()
    }
}

private extension TencentLiveTranscriber {
    struct CompletionEnvelope: Decodable {
        let final: Int?
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

            let data: Data
            switch message {
            case let .data(receivedData):
                data = receivedData
            case let .text(text):
                data = Data(text.utf8)
            }

            do {
                let events = try decoder.decode(data)
                let completion = try JSONDecoder().decode(CompletionEnvelope.self, from: data)
                for event in events {
                    eventContinuation.yield(event)
                }

                if completion.final == 1 {
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
        guard generation == connectionGeneration else { return }
        if finishRequested {
            await completeSuccessfully()
            return
        }
        _ = await recover(from: generation)
    }

    func recover(from failedGeneration: Int) async -> Bool {
        if let reconnectTask {
            return await reconnectTask.value
        }

        guard state == .live,
              failedGeneration == connectionGeneration,
              !finishRequested
        else {
            return state == .live && !finishRequested
        }

        state = .reconnecting
        lastAudioSendNanoseconds = nil
        let failedConnection = connection
        connection = nil
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.performReconnects()
        }
        reconnectTask = task
        await failedConnection?.cancel()
        return await task.value
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

            do {
                let url = try signedURL(configuration: retryConfiguration)
                let newConnection = try await transport.connect(to: url)
                guard !Task.isCancelled, state == .reconnecting else {
                    await newConnection.cancel()
                    reconnectTask = nil
                    return false
                }

                connectionGeneration += 1
                connection = newConnection
                state = .live
                reconnectTask = nil
                startReceiving(on: newConnection, generation: connectionGeneration)
                return true
            } catch {
                continue
            }
        }

        reconnectTask = nil
        await fail(with: TencentLiveTranscriberError.reconnectLimitExceeded)
        return false
    }

    func transmit(_ frame: Data) async throws {
        while true {
            guard !finishRequested, state != .finished else {
                throw TencentLiveTranscriberError.finished
            }
            if state == .reconnecting, let reconnectTask {
                guard await reconnectTask.value else {
                    throw errorForCurrentState()
                }
            }
            guard state == .live, let connection else {
                throw errorForCurrentState()
            }

            let generation = connectionGeneration
            do {
                try await paceNextAudioFrame()
                try await connection.send(.data(frame))
                lastAudioSendNanoseconds = await scheduler.nowNanoseconds()
                return
            } catch is CancellationError {
                throw TencentLiveTranscriberError.connectionFailed
            } catch {
                guard await recover(from: generation) else {
                    throw errorForCurrentState()
                }
            }
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
        finishRequested = true
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        let connection = self.connection
        self.connection = nil
        configuration = nil
        pendingPCM.removeAll(keepingCapacity: false)
        state = .finished
        eventContinuation.finish()
        await connection?.cancel()
    }

    func completeSuccessfully() async {
        guard state != .finished else { return }
        finishRequested = true
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask = nil
        let connection = self.connection
        self.connection = nil
        configuration = nil
        pendingPCM.removeAll(keepingCapacity: false)
        state = .finished
        eventContinuation.finish()
        await connection?.cancel()
    }

    func fail(with error: Error) async {
        guard state != .failed, state != .finished else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        let connection = self.connection
        self.connection = nil
        configuration = nil
        pendingPCM.removeAll(keepingCapacity: false)
        state = .failed
        eventContinuation.finish(throwing: error)
        await connection?.cancel()
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
