import CoreAudio
import Darwin
import Dispatch
import Foundation
import Observation

/// Audio-capture seam kept deliberately narrower than `AudioCaptureManager`.
/// The synchronous PCM sink runs on Core Audio's real-time callback thread.
@MainActor
protocol LiveAudioCapturing: AnyObject {
    var hasPendingCaptureResources: Bool { get }
    func startLiveCapture(
        processObjectID: AudioObjectID,
        onPCM: @escaping @Sendable (Data) -> Void
    ) async throws
    func stopCapture() async throws
    func emergencyStop()
}

@available(macOS 14.2, *)
extension AudioCaptureManager: LiveAudioCapturing {}

/// Observes only the selected meeting process. Tests inject a manual observer.
@MainActor
protocol LiveMeetingProcessObserving: AnyObject {
    func observeExit(
        of processID: pid_t,
        handler: @escaping @MainActor @Sendable () -> Void
    )
    func stopObserving()
}

enum LiveTranscriberConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case live
    case reconnecting
    case finished
    case failed
}

/// Optional provider status stream used to reflect reconnecting without
/// coupling the coordinator to Tencent's actor implementation.
protocol LiveTranscriberConnectionStateReporting: Sendable {
    func connectionStateUpdates() -> AsyncStream<LiveTranscriberConnectionState>
}

@MainActor
private final class SystemLiveMeetingProcessObserver: LiveMeetingProcessObserving {
    private var exitSource: DispatchSourceProcess?
    private var observedPID: pid_t?

    func observeExit(
        of processID: pid_t,
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        stopObserving()
        observedPID = processID
        guard kill(processID, 0) == 0 || errno == EPERM else {
            Task { @MainActor [weak self] in
                guard self?.observedPID == processID else { return }
                handler()
            }
            return
        }

        let source = DispatchSource.makeProcessSource(
            identifier: processID,
            eventMask: .exit,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard self?.observedPID == processID else { return }
                handler()
            }
        }
        exitSource = source
        source.resume()
    }

    func stopObserving() {
        exitSource?.cancel()
        exitSource = nil
        observedPID = nil
    }

    deinit {
        exitSource?.cancel()
    }
}

enum LiveMeetingCoordinatorError: LocalizedError, Equatable {
    case captureStartFailed
    case captureStopFailed
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .captureStartFailed:
            "Could not start audio capture for the selected application."
        case .captureStopFailed:
            "Could not completely stop audio capture."
        case .transcriptionFailed:
            "Live transcription could not be started or recovered."
        }
    }
}

private enum LiveCaptureStartOutcome: Sendable {
    case success
    case failure
}

private enum PCMTerminationPolicy: Sendable {
    case drain
    case discard
}

private enum TranscriberTerminationPolicy: Sendable, Equatable {
    case finish
    case cancel
}

private struct LiveMeetingTeardownOutcome: Sendable {
    let captureCleanupFailed: Bool
}

private struct LiveMeetingTeardownOperation {
    let id: UUID
    let transcriberPolicy: TranscriberTerminationPolicy
    let task: Task<LiveMeetingTeardownOutcome, Never>
}

private enum LiveMeetingSessionIntent: Equatable, Sendable {
    case startup
    case running
    case terminal(LiveConnectionState)
}

@MainActor
private final class LiveMeetingSession {
    let generation: Int
    let process: AudioProcessInfo
    let buffer: PCMChunkBuffer
    let transcriber: any LiveTranscriber

    var captureStartTask: Task<LiveCaptureStartOutcome, Never>?
    var senderTask: Task<Void, Never>?
    var eventTask: Task<Void, Never>?
    var connectionStateTask: Task<Void, Never>?
    var dropMonitorTask: Task<Void, Never>?
    var teardownOperation: LiveMeetingTeardownOperation?
    var pipelineFailed = false
    var handledReconnectDiscardSequence = 0
    var hasInFlightPCM = false
    var intent: LiveMeetingSessionIntent = .startup

    var acceptsStartupCompletion: Bool {
        intent == .startup
    }

    func requestTerminalState(_ state: LiveConnectionState) {
        intent = .terminal(state)
    }

    init(
        generation: Int,
        process: AudioProcessInfo,
        bufferCapacity: Int,
        transcriber: any LiveTranscriber
    ) {
        self.generation = generation
        self.process = process
        buffer = PCMChunkBuffer(capacity: bufferCapacity)
        self.transcriber = transcriber
    }
}

/// Coordinates one memory-only live meeting from process audio to transcript.
///
/// Capture, PCM sending, and transcript consumption stay separate. The Core
/// Audio callback does exactly one operation: `PCMChunkBuffer.push(_:)`.
/// Assistant/LLM work is intentionally absent from this dependency graph.
@available(macOS 14.2, *)
@Observable
@MainActor
final class LiveMeetingCoordinator {
    private(set) var state: LiveConnectionState = .idle
    private(set) var lastError: String?
    private var reportedDroppedChunkCount = 0

    var droppedChunkCount: Int {
        max(reportedDroppedChunkCount, activeSession?.buffer.discardedCount ?? 0)
    }

    @ObservationIgnored
    private let capture: any LiveAudioCapturing
    @ObservationIgnored
    private let transcriptStore: LiveTranscriptStore
    @ObservationIgnored
    private let transcriberFactory: @MainActor () -> any LiveTranscriber
    @ObservationIgnored
    private let configurationProvider: @MainActor () throws -> ASRConfiguration
    @ObservationIgnored
    private let processObserver: any LiveMeetingProcessObserving
    @ObservationIgnored
    private let bufferCapacity: Int
    @ObservationIgnored
    private let sessionClockFactory: @MainActor () -> any MeetingSessionClock
    @ObservationIgnored
    private let dropMonitorIntervalNanoseconds: UInt64

    nonisolated static let defaultDropMonitorIntervalNanoseconds: UInt64 = 250_000_000

    @ObservationIgnored
    private var sessionGeneration = 0
    @ObservationIgnored
    private var activeSession: LiveMeetingSession?

    init(
        capture: any LiveAudioCapturing,
        transcriptStore: LiveTranscriptStore,
        transcriberFactory: @escaping @MainActor () -> any LiveTranscriber,
        configurationProvider: @escaping @MainActor () throws -> ASRConfiguration,
        processObserver: (any LiveMeetingProcessObserving)? = nil,
        bufferCapacity: Int = 64,
        dropMonitorIntervalNanoseconds: UInt64 = LiveMeetingCoordinator
            .defaultDropMonitorIntervalNanoseconds,
        sessionClockFactory: @escaping @MainActor () -> any MeetingSessionClock = {
            MonotonicMeetingSessionClock()
        }
    ) {
        self.capture = capture
        self.transcriptStore = transcriptStore
        self.transcriberFactory = transcriberFactory
        self.configurationProvider = configurationProvider
        self.processObserver = processObserver ?? SystemLiveMeetingProcessObserver()
        self.bufferCapacity = bufferCapacity
        self.dropMonitorIntervalNanoseconds = dropMonitorIntervalNanoseconds
        self.sessionClockFactory = sessionClockFactory
    }

    /// Starts a fresh, memory-only meeting for the exact Core Audio process.
    func start(process: AudioProcessInfo) async {
        await clearAndClose()
        guard activeSession == nil else { return }
        guard !capture.hasPendingCaptureResources else {
            lastError = LiveMeetingCoordinatorError.captureStopFailed.localizedDescription
            transition(to: .error)
            return
        }

        sessionGeneration += 1
        let session = LiveMeetingSession(
            generation: sessionGeneration,
            process: process,
            bufferCapacity: bufferCapacity,
            transcriber: transcriberFactory()
        )
        activeSession = session
        lastError = nil
        reportedDroppedChunkCount = 0
        transcriptStore.clear()
        transcriptStore.beginMeeting(clock: sessionClockFactory())
        transition(to: .connecting)

        do {
            try await session.transcriber.connect(
                configuration: configurationProvider()
            )
        } catch {
            guard isActive(session), session.acceptsStartupCompletion else { return }
            await failStart(session: session, error: .transcriptionFailed)
            return
        }

        guard isActive(session), session.acceptsStartupCompletion else { return }

        startEventTask(for: session)
        startSenderTask(for: session)
        startDropMonitorTask(for: session)

        let buffer = session.buffer
        let capture = self.capture
        let captureStartTask = Task { @MainActor in
            do {
                try await capture.startLiveCapture(
                    processObjectID: process.id,
                    onPCM: { pcm in
                        _ = buffer.push(pcm)
                    }
                )
                return LiveCaptureStartOutcome.success
            } catch {
                return LiveCaptureStartOutcome.failure
            }
        }
        session.captureStartTask = captureStartTask

        switch await captureStartTask.value {
        case .failure:
            guard isActive(session), session.acceptsStartupCompletion else { return }
            await failStart(session: session, error: .captureStartFailed)
            return

        case .success:
            guard isActive(session),
                  session.acceptsStartupCompletion,
                  state == .connecting
            else { return }
        }

        session.intent = .running
        processObserver.observeExit(of: process.pid) { [weak self] in
            guard let self else { return }
            Task { await self.processDidExit(pid: process.pid) }
        }
        transition(to: .live)
        startConnectionStateTask(for: session)
    }

    /// Gracefully stops capture, drains accepted PCM, then finishes ASR.
    func stop() async {
        guard state == .connecting || state == .live || state == .reconnecting else {
            return
        }
        await endActiveSession(finalState: .review, error: nil)
    }

    /// Testable entry point shared by the process observer.
    func processDidExit(pid: pid_t) async {
        guard activeSession?.process.pid == pid else { return }
        await stop()
    }

    /// Stops any live work, cancels provider resources, and clears all content.
    func clearAndClose() async {
        guard let session = activeSession else {
            transcriptStore.clear()
            reportedDroppedChunkCount = 0
            if capture.hasPendingCaptureResources {
                lastError = LiveMeetingCoordinatorError.captureStopFailed.localizedDescription
                transition(to: .error)
            } else {
                lastError = nil
                transition(to: .idle)
            }
            return
        }

        processObserver.stopObserving()
        session.requestTerminalState(.idle)
        session.buffer.discardAndFinish()
        session.eventTask?.cancel()
        session.connectionStateTask?.cancel()
        transcriptStore.clear()

        let outcome = await teardown(
            session,
            pcmPolicy: .discard,
            transcriberPolicy: .cancel
        )

        guard isActive(session) else { return }
        transcriptStore.clear()
        if outcome.captureCleanupFailed || capture.hasPendingCaptureResources {
            session.requestTerminalState(.error)
            lastError = LiveMeetingCoordinatorError.captureStopFailed.localizedDescription
            transition(to: .error)
        } else {
            session.requestTerminalState(.idle)
            activeSession = nil
            reportedDroppedChunkCount = 0
            lastError = nil
            transition(to: .idle)
        }
    }

    /// Synchronous process-exit cleanup. Meeting content is cleared before
    /// this method returns; asynchronous socket cancellation is best-effort.
    func shutdown() {
        processObserver.stopObserving()
        let session = activeSession
        session?.requestTerminalState(.idle)
        session?.buffer.discardAndFinish()
        session?.senderTask?.cancel()
        session?.eventTask?.cancel()
        session?.connectionStateTask?.cancel()
        session?.dropMonitorTask?.cancel()
        session?.captureStartTask?.cancel()
        session?.teardownOperation?.task.cancel()

        capture.emergencyStop()
        let cleanupStillPending = capture.hasPendingCaptureResources
        if let session {
            mirrorDroppedChunkCount(from: session)
        }
        activeSession = nil
        reportedDroppedChunkCount = 0
        sessionGeneration += 1
        transcriptStore.clear()
        if cleanupStillPending {
            lastError = LiveMeetingCoordinatorError.captureStopFailed.localizedDescription
            transition(to: .error)
        } else {
            lastError = nil
            transition(to: .idle)
        }

        if let transcriber = session?.transcriber {
            Task { await transcriber.cancel() }
        }
    }
}

@available(macOS 14.2, *)
private extension LiveMeetingCoordinator {
    func startConnectionStateTask(for session: LiveMeetingSession) {
        guard let reporter = session.transcriber
                as? any LiveTranscriberConnectionStateReporting
        else { return }

        session.connectionStateTask = Task { [weak self, weak session] in
            for await providerState in reporter.connectionStateUpdates() {
                guard !Task.isCancelled,
                      let self,
                      let session,
                      self.isActive(session)
                else { return }

                switch providerState {
                case .reconnecting:
                    if self.state == .live {
                        self.transition(to: .reconnecting)
                    }
                case .live:
                    guard self.state == .reconnecting else { break }
                    self.transition(to: .live)
                    if !session.hasInFlightPCM,
                       let discard = await session.transcriber.reconnectDiscardStatus() {
                        guard self.isActive(session) else { return }
                        await self.handleReconnectDiscard(discard, for: session)
                    }
                case .idle, .connecting, .finished, .failed:
                    break
                }
            }
        }
    }

    func startSenderTask(for session: LiveMeetingSession) {
        let buffer = session.buffer
        let transcriber = session.transcriber
        let generation = session.generation
        session.senderTask = Task { [weak self] in
            while !Task.isCancelled {
                if let pcm = buffer.pop() {
                    session.hasInFlightPCM = true
                    do {
                        let result = try await transcriber.send(pcm)
                        session.hasInFlightPCM = false
                        if case .reconnectDiscardRequired = result {
                            await self?.handleReconnectDiscard(result, for: session)
                        }
                    } catch {
                        session.hasInFlightPCM = false
                        if Task.isCancelled { return }
                        Task { @MainActor [weak self] in
                            await self?.pipelineDidFail(generation: generation)
                        }
                        return
                    }
                    continue
                }

                if buffer.isFinishedAndEmpty {
                    if let discard = await transcriber.reconnectDiscardStatus() {
                        await self?.handleReconnectDiscard(discard, for: session)
                    }
                    return
                }
                try? await Task<Never, Never>.sleep(nanoseconds: 2_000_000)
            }
        }
    }

    func startDropMonitorTask(for session: LiveMeetingSession) {
        session.dropMonitorTask = Task { [weak self, weak session] in
            while !Task.isCancelled {
                guard let self,
                      let session,
                      self.isActive(session)
                else { return }
                self.mirrorDroppedChunkCount(from: session)
                try? await Task<Never, Never>.sleep(
                    nanoseconds: self.dropMonitorIntervalNanoseconds
                )
            }
        }
    }

    func mirrorDroppedChunkCount(from session: LiveMeetingSession) {
        guard isActive(session) else { return }
        let discardedChunkCount = session.buffer.discardedCount
        guard reportedDroppedChunkCount != discardedChunkCount else { return }
        reportedDroppedChunkCount = discardedChunkCount
    }

    func handleReconnectDiscard(
        _ result: LiveTranscriberSendResult,
        for session: LiveMeetingSession
    ) async {
        guard isActive(session),
              case let .reconnectDiscardRequired(sequence, _) = result,
              sequence > session.handledReconnectDiscardSequence
        else { return }

        session.handledReconnectDiscardSequence = sequence
        session.buffer.discardQueued()
        let providerDiscardedChunkCount = await session.transcriber
            .acknowledgeReconnectDiscard(sequence: sequence)
        guard isActive(session) else { return }
        session.buffer.recordDiscarded(providerDiscardedChunkCount)
        mirrorDroppedChunkCount(from: session)
    }

    func startEventTask(for session: LiveMeetingSession) {
        let transcriber = session.transcriber
        session.eventTask = Task { [weak self, weak session] in
            do {
                for try await event in transcriber.events() {
                    guard !Task.isCancelled,
                          let self,
                          let session,
                          self.isActive(session)
                    else { return }
                    self.transcriptStore.apply(event)
                }

                guard !Task.isCancelled,
                      let self,
                      let session,
                      self.isActive(session),
                      session.teardownOperation == nil,
                      self.state != .review,
                      self.state != .error
                else { return }
                await self.pipelineDidFail(generation: session.generation)
            } catch {
                guard !Task.isCancelled,
                      let self,
                      let session,
                      self.isActive(session)
                else { return }
                await self.pipelineDidFail(generation: session.generation)
            }
        }
    }

    func pipelineDidFail(generation: Int) async {
        guard let session = activeSession,
              session.generation == generation
        else { return }
        if case .terminal = session.intent { return }
        session.pipelineFailed = true
        lastError = LiveMeetingCoordinatorError.transcriptionFailed.localizedDescription
        await endActiveSession(
            finalState: .error,
            error: .transcriptionFailed
        )
    }

    func endActiveSession(
        finalState: LiveConnectionState,
        error: LiveMeetingCoordinatorError?
    ) async {
        guard let session = activeSession else { return }
        session.requestTerminalState(error == nil ? finalState : .error)
        processObserver.stopObserving()

        let outcome = await teardown(
            session,
            pcmPolicy: .drain,
            transcriberPolicy: .finish
        )
        guard isActive(session) else { return }

        let terminalError: LiveMeetingCoordinatorError?
        if outcome.captureCleanupFailed || capture.hasPendingCaptureResources {
            terminalError = .captureStopFailed
        } else if let error {
            terminalError = error
        } else if session.pipelineFailed {
            terminalError = .transcriptionFailed
        } else {
            terminalError = nil
        }

        if let terminalError {
            session.requestTerminalState(.error)
            lastError = terminalError.localizedDescription
            transition(to: .error)
        } else {
            session.requestTerminalState(finalState)
            lastError = nil
            transition(to: finalState)
        }
    }

    func failStart(
        session: LiveMeetingSession,
        error: LiveMeetingCoordinatorError
    ) async {
        guard isActive(session), session.acceptsStartupCompletion else { return }

        session.requestTerminalState(.error)
        processObserver.stopObserving()
        session.buffer.discardAndFinish()
        session.eventTask?.cancel()
        session.connectionStateTask?.cancel()
        let outcome = await teardown(
            session,
            pcmPolicy: .discard,
            transcriberPolicy: .cancel
        )
        guard isActive(session) else { return }

        if outcome.captureCleanupFailed || capture.hasPendingCaptureResources {
            lastError = LiveMeetingCoordinatorError.captureStopFailed.localizedDescription
        } else {
            activeSession = nil
            lastError = error.localizedDescription
        }
        transition(to: .error)
    }

    func teardown(
        _ session: LiveMeetingSession,
        pcmPolicy: PCMTerminationPolicy,
        transcriberPolicy: TranscriberTerminationPolicy
    ) async -> LiveMeetingTeardownOutcome {
        if pcmPolicy == .discard {
            session.buffer.discardAndFinish()
            session.senderTask?.cancel()
        }

        if let operation = session.teardownOperation {
            let outcome = await operation.task.value
            if transcriberPolicy == .cancel,
               operation.transcriberPolicy != .cancel {
                session.eventTask?.cancel()
                await session.transcriber.cancel()
            }
            clearTeardownOperation(operation.id, from: session)
            return outcome
        }

        let operationID = UUID()
        let capture = self.capture
        let task = Task { @MainActor in
            if let captureStartTask = session.captureStartTask {
                _ = await captureStartTask.value
            }

            var cleanupFailed = false
            if capture.hasPendingCaptureResources {
                do {
                    try await capture.stopCapture()
                } catch {
                    cleanupFailed = true
                }
            }
            if capture.hasPendingCaptureResources {
                cleanupFailed = true
            }

            switch pcmPolicy {
            case .drain:
                session.buffer.finish()
            case .discard:
                session.buffer.discardAndFinish()
            }
            await session.senderTask?.value
            session.senderTask = nil
            self.mirrorDroppedChunkCount(from: session)
            session.dropMonitorTask?.cancel()
            session.dropMonitorTask = nil
            session.connectionStateTask?.cancel()
            session.connectionStateTask = nil

            switch transcriberPolicy {
            case .finish:
                await session.transcriber.finish()
            case .cancel:
                session.eventTask?.cancel()
                session.eventTask = nil
                await session.transcriber.cancel()
            }

            return LiveMeetingTeardownOutcome(
                captureCleanupFailed: cleanupFailed
            )
        }
        let operation = LiveMeetingTeardownOperation(
            id: operationID,
            transcriberPolicy: transcriberPolicy,
            task: task
        )
        session.teardownOperation = operation
        let outcome = await task.value
        clearTeardownOperation(operationID, from: session)
        return outcome
    }

    func clearTeardownOperation(
        _ operationID: UUID,
        from session: LiveMeetingSession
    ) {
        guard session.teardownOperation?.id == operationID else { return }
        session.teardownOperation = nil
    }

    func transition(to newState: LiveConnectionState) {
        state = newState
        transcriptStore.connectionState = newState
    }

    func isActive(_ session: LiveMeetingSession) -> Bool {
        activeSession === session
    }
}
