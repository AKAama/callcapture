import CoreAudio
import Darwin
import Dispatch
import Foundation
import Observation

/// Audio-capture seam kept deliberately narrower than `AudioCaptureManager`.
/// The synchronous PCM sink runs on Core Audio's real-time callback thread.
@MainActor
protocol LiveAudioCapturing: AnyObject {
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

    var droppedChunkCount: Int { pcmBuffer.discardedCount }

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
    private let pcmBuffer: PCMChunkBuffer

    @ObservationIgnored
    private var transcriber: (any LiveTranscriber)?
    @ObservationIgnored
    private var senderTask: Task<Void, Never>?
    @ObservationIgnored
    private var eventTask: Task<Void, Never>?
    @ObservationIgnored
    private var connectionStateTask: Task<Void, Never>?
    @ObservationIgnored
    private var selectedProcess: AudioProcessInfo?
    @ObservationIgnored
    private var sessionGeneration = 0
    @ObservationIgnored
    private var activeGeneration: Int?
    @ObservationIgnored
    private var captureStarted = false
    @ObservationIgnored
    private var isEnding = false
    @ObservationIgnored
    private var pipelineFailed = false

    init(
        capture: any LiveAudioCapturing,
        transcriptStore: LiveTranscriptStore,
        transcriberFactory: @escaping @MainActor () -> any LiveTranscriber,
        configurationProvider: @escaping @MainActor () throws -> ASRConfiguration,
        processObserver: (any LiveMeetingProcessObserving)? = nil,
        bufferCapacity: Int = 64
    ) {
        self.capture = capture
        self.transcriptStore = transcriptStore
        self.transcriberFactory = transcriberFactory
        self.configurationProvider = configurationProvider
        self.processObserver = processObserver ?? SystemLiveMeetingProcessObserver()
        pcmBuffer = PCMChunkBuffer(capacity: bufferCapacity)
    }

    /// Starts a fresh, memory-only meeting for the exact Core Audio process.
    func start(process: AudioProcessInfo) async {
        await clearAndClose()
        guard !captureStarted else { return }

        sessionGeneration += 1
        let generation = sessionGeneration
        activeGeneration = generation
        selectedProcess = process
        pipelineFailed = false
        lastError = nil
        pcmBuffer.clear()
        transcriptStore.clear()
        transition(to: .connecting)

        let transcriber = transcriberFactory()
        self.transcriber = transcriber

        do {
            try await transcriber.connect(configuration: configurationProvider())
        } catch {
            guard isCurrent(generation), state == .connecting else {
                await transcriber.cancel()
                return
            }
            await failStart(
                generation: generation,
                transcriber: transcriber,
                error: .transcriptionFailed
            )
            return
        }

        guard isCurrent(generation), state == .connecting else {
            await transcriber.cancel()
            return
        }

        startEventTask(transcriber: transcriber, generation: generation)
        startSenderTask(transcriber: transcriber, generation: generation)

        do {
            let buffer = pcmBuffer
            try await capture.startLiveCapture(
                processObjectID: process.id,
                onPCM: { pcm in
                    _ = buffer.push(pcm)
                }
            )
        } catch {
            guard isCurrent(generation), state == .connecting else {
                await transcriber.cancel()
                return
            }
            await failStart(
                generation: generation,
                transcriber: transcriber,
                error: .captureStartFailed
            )
            return
        }

        guard isCurrent(generation), state == .connecting else {
            captureStarted = true
            do {
                try await capture.stopCapture()
                captureStarted = false
            } catch {
                pcmBuffer.finish()
                lastError = LiveMeetingCoordinatorError.captureStopFailed.localizedDescription
                transition(to: .error)
            }
            return
        }

        captureStarted = true
        processObserver.observeExit(of: process.pid) { [weak self] in
            guard let self else { return }
            Task { await self.processDidExit(pid: process.pid) }
        }
        transition(to: .live)
        startConnectionStateTask(transcriber: transcriber, generation: generation)
    }

    /// Gracefully stops capture, drains accepted PCM, then finishes ASR.
    func stop() async {
        guard state == .connecting || state == .live || state == .reconnecting else {
            return
        }
        await endActiveSession(finalState: .review, error: nil)
    }

    /// Testable entry point shared by the AppKit process observer.
    func processDidExit(pid: pid_t) async {
        guard selectedProcess?.pid == pid else { return }
        await stop()
    }

    /// Stops any live work, cancels provider resources, and clears all content.
    func clearAndClose() async {
        if state == .connecting || state == .live || state == .reconnecting {
            await endActiveSession(finalState: .review, error: nil)
        }

        processObserver.stopObserving()
        invalidateActiveSession()
        senderTask?.cancel()
        eventTask?.cancel()
        connectionStateTask?.cancel()
        let senderTask = self.senderTask
        let transcriber = self.transcriber
        self.senderTask = nil
        self.eventTask = nil
        self.connectionStateTask = nil
        self.transcriber = nil
        await transcriber?.cancel()
        await senderTask?.value

        if captureStarted {
            do {
                try await capture.stopCapture()
                captureStarted = false
            } catch {
                lastError = LiveMeetingCoordinatorError.captureStopFailed.localizedDescription
            }
        }
        pcmBuffer.finish()
        pcmBuffer.clear()
        if captureStarted {
            // A HAL callback may still be registered after a cleanup failure.
            // Keep the queue closed so it cannot retain any new audio.
            pcmBuffer.finish()
        }
        transcriptStore.clear()
        selectedProcess = nil
        isEnding = false
        pipelineFailed = false
        if captureStarted {
            transition(to: .error)
        } else {
            lastError = nil
            transition(to: .idle)
        }
    }

    /// Synchronous process-exit cleanup. Meeting content is cleared before
    /// this method returns; asynchronous socket cancellation is best-effort.
    func shutdown() {
        processObserver.stopObserving()
        invalidateActiveSession()
        capture.emergencyStop()
        captureStarted = false
        pcmBuffer.finish()
        senderTask?.cancel()
        eventTask?.cancel()
        connectionStateTask?.cancel()
        senderTask = nil
        eventTask = nil
        connectionStateTask = nil
        let transcriber = self.transcriber
        self.transcriber = nil
        pcmBuffer.clear()
        pcmBuffer.finish()
        transcriptStore.clear()
        selectedProcess = nil
        isEnding = false
        pipelineFailed = false
        lastError = nil
        transition(to: .idle)

        if let transcriber {
            Task { await transcriber.cancel() }
        }
    }
}

@available(macOS 14.2, *)
private extension LiveMeetingCoordinator {
    func startConnectionStateTask(
        transcriber: any LiveTranscriber,
        generation: Int
    ) {
        guard let reporter = transcriber as? any LiveTranscriberConnectionStateReporting else {
            return
        }

        connectionStateTask = Task { [weak self] in
            for await providerState in reporter.connectionStateUpdates() {
                guard !Task.isCancelled,
                      let self,
                      self.isCurrent(generation)
                else { return }

                switch providerState {
                case .reconnecting:
                    if self.state == .live {
                        self.transition(to: .reconnecting)
                    }
                case .live:
                    if self.state == .reconnecting {
                        self.transition(to: .live)
                    }
                case .idle, .connecting, .finished, .failed:
                    break
                }
            }
        }
    }

    func startSenderTask(
        transcriber: any LiveTranscriber,
        generation: Int
    ) {
        let buffer = pcmBuffer
        senderTask = Task { [weak self] in
            while !Task.isCancelled {
                if let pcm = buffer.pop() {
                    do {
                        try await transcriber.send(pcm)
                    } catch {
                        Task { @MainActor [weak self] in
                            await self?.pipelineDidFail(generation: generation)
                        }
                        return
                    }
                    continue
                }

                if buffer.isFinishedAndEmpty { return }
                try? await Task<Never, Never>.sleep(nanoseconds: 2_000_000)
            }
        }
    }

    func startEventTask(
        transcriber: any LiveTranscriber,
        generation: Int
    ) {
        eventTask = Task { [weak self] in
            do {
                for try await event in transcriber.events() {
                    guard !Task.isCancelled,
                          let self,
                          self.isCurrent(generation)
                    else { return }
                    self.transcriptStore.apply(event)
                }

                guard !Task.isCancelled,
                      let self,
                      self.isCurrent(generation),
                      !self.isEnding,
                      self.state != .review,
                      self.state != .error
                else { return }
                await self.pipelineDidFail(generation: generation)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.pipelineDidFail(generation: generation)
            }
        }
    }

    func pipelineDidFail(generation: Int) async {
        guard isCurrent(generation) else { return }
        pipelineFailed = true
        lastError = LiveMeetingCoordinatorError.transcriptionFailed.localizedDescription
        guard !isEnding else { return }
        await endActiveSession(
            finalState: .error,
            error: .transcriptionFailed
        )
    }

    func endActiveSession(
        finalState: LiveConnectionState,
        error: LiveMeetingCoordinatorError?
    ) async {
        guard activeGeneration != nil, !isEnding else { return }
        isEnding = true
        processObserver.stopObserving()

        var terminalError = error
        if captureStarted {
            do {
                try await capture.stopCapture()
                captureStarted = false
            } catch {
                terminalError = .captureStopFailed
            }
        }

        // No producer remains after capture stops. Finishing the queue lets the
        // sender drain every accepted chunk and then exit deterministically.
        pcmBuffer.finish()
        await senderTask?.value
        senderTask = nil

        connectionStateTask?.cancel()
        connectionStateTask = nil
        await transcriber?.finish()

        if pipelineFailed, terminalError == nil {
            terminalError = .transcriptionFailed
        }
        if let terminalError {
            lastError = terminalError.localizedDescription
            transition(to: .error)
        } else {
            lastError = nil
            transition(to: finalState)
        }
        isEnding = false
    }

    func failStart(
        generation: Int,
        transcriber: any LiveTranscriber,
        error: LiveMeetingCoordinatorError
    ) async {
        guard isCurrent(generation) else {
            await transcriber.cancel()
            return
        }

        processObserver.stopObserving()
        if captureStarted {
            try? await capture.stopCapture()
            captureStarted = false
        }
        pcmBuffer.finish()
        await senderTask?.value
        senderTask?.cancel()
        eventTask?.cancel()
        connectionStateTask?.cancel()
        senderTask = nil
        eventTask = nil
        connectionStateTask = nil
        await transcriber.cancel()
        self.transcriber = nil
        selectedProcess = nil
        activeGeneration = nil
        pipelineFailed = true
        lastError = error.localizedDescription
        transition(to: .error)
    }

    func transition(to newState: LiveConnectionState) {
        state = newState
        transcriptStore.connectionState = newState
    }

    func isCurrent(_ generation: Int) -> Bool {
        activeGeneration == generation
    }

    func invalidateActiveSession() {
        sessionGeneration += 1
        activeGeneration = nil
    }
}
