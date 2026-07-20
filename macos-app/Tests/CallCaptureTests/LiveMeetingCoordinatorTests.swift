import CoreAudio
import Foundation
import Testing
@testable import CallCapture

@Suite("LiveMeetingCoordinator")
struct LiveMeetingCoordinatorTests {
    @Test("开始会议会连接 ASR、启动所选进程采集并进入 live")
    @MainActor func startsSelectedProcessMeeting() async {
        let harness = Harness()

        await harness.coordinator.start(process: Self.process)

        #expect(harness.coordinator.state == .live)
        #expect(harness.store.connectionState == .live)
        #expect(harness.capture.startedProcessIDs == [Self.process.id])
        #expect(await harness.transcriber.connectCount == 1)
        await harness.coordinator.clearAndClose()
    }

    @Test("手动停止先停采集、排空队列，再结束 ASR 并进入 review")
    @MainActor func stopsInPrivacyPreservingOrder() async {
        let recorder = CoordinatorOperationRecorder()
        let harness = Harness(recorder: recorder)
        await harness.coordinator.start(process: Self.process)
        harness.capture.emit(Data([1, 2, 3]))

        await harness.coordinator.stop()

        let operations = await recorder.operations
        #expect(harness.coordinator.state == .review)
        #expect(operations.contains("asr.send"))
        #expect(operations.firstIndex(of: "capture.stop")! < operations.firstIndex(of: "asr.finish")!)
        #expect(operations.firstIndex(of: "asr.send")! < operations.firstIndex(of: "asr.finish")!)
        await harness.coordinator.clearAndClose()
    }

    @Test("只有所选会议进程退出才会自动停止并保留字幕供 review")
    @MainActor func stopsWhenSelectedProcessExits() async {
        let harness = Harness()
        await harness.coordinator.start(process: Self.process)
        await harness.transcriber.emit(.confirmed(
            id: "kept",
            speakerID: "1",
            text: "保留已有字幕",
            startMS: 0,
            endMS: 1_000
        ))
        await waitUntil { harness.store.confirmedUtterances.count == 1 }

        await harness.coordinator.processDidExit(pid: Self.process.pid + 1)
        #expect(harness.coordinator.state == .live)

        await harness.coordinator.processDidExit(pid: Self.process.pid)

        #expect(harness.coordinator.state == .review)
        #expect(harness.capture.stopCount == 1)
        #expect(harness.store.confirmedUtterances.map(\.id) == ["kept"])
        await harness.coordinator.clearAndClose()
    }

    @Test("ASR 重试耗尽会停止采集、进入 error，并保留已确认字幕")
    @MainActor func handlesExhaustedASRRetries() async {
        let harness = Harness()
        await harness.coordinator.start(process: Self.process)
        await harness.transcriber.emit(.confirmed(
            id: "before-error",
            speakerID: "1",
            text: "错误前字幕",
            startMS: 0,
            endMS: 1_000
        ))
        await waitUntil { harness.store.confirmedUtterances.count == 1 }

        await harness.transcriber.fail(TencentLiveTranscriberError.reconnectLimitExceeded)
        await waitUntil { harness.coordinator.state == .error }

        #expect(harness.capture.stopCount == 1)
        #expect(harness.store.confirmedUtterances.map(\.id) == ["before-error"])
        #expect(harness.coordinator.lastError != nil)
        await harness.coordinator.clearAndClose()
    }

    @Test("ASR 重连状态只暂停连接展示，恢复后返回 live")
    @MainActor func mirrorsASRReconnectState() async {
        let harness = Harness()
        await harness.coordinator.start(process: Self.process)

        await harness.transcriber.emitConnectionState(.reconnecting)
        await waitUntil { harness.coordinator.state == .reconnecting }
        #expect(harness.capture.stopCount == 0)

        await harness.transcriber.emitConnectionState(.live)
        await waitUntil { harness.coordinator.state == .live }
        #expect(harness.capture.stopCount == 0)
        await harness.coordinator.clearAndClose()
    }

    @Test("独立的 LLM 请求失败不会改变实时会议状态")
    @MainActor func ignoresUnrelatedAssistantFailure() async {
        let harness = Harness()
        await harness.coordinator.start(process: Self.process)

        let assistantRequest = Task { () throws -> Void in
            throw FakeAssistantError.unavailable
        }
        _ = await assistantRequest.result

        #expect(harness.coordinator.state == .live)
        #expect(harness.capture.stopCount == 0)
        await harness.coordinator.clearAndClose()
    }

    @Test("开始下一场会议会在创建新 ASR 连接前清空上一场内存内容")
    @MainActor func clearsPreviousMeetingBeforeStartingAnother() async {
        let store = LiveTranscriptStore()
        let firstTranscriber = FakeLiveTranscriber()
        let secondTranscriber = FakeLiveTranscriber()
        var transcribers: [FakeLiveTranscriber] = [firstTranscriber, secondTranscriber]
        var transcriptCountsAtConfiguration: [Int] = []
        let coordinator = LiveMeetingCoordinator(
            capture: FakeLiveCapture(),
            transcriptStore: store,
            transcriberFactory: { transcribers.removeFirst() },
            configurationProvider: {
                transcriptCountsAtConfiguration.append(store.confirmedUtterances.count)
                return Self.configuration
            },
            processObserver: FakeMeetingProcessObserver()
        )

        await coordinator.start(process: Self.process)
        await firstTranscriber.emit(.confirmed(
            id: "old",
            speakerID: "1",
            text: "上一场",
            startMS: 0,
            endMS: 1_000
        ))
        await waitUntil { store.confirmedUtterances.count == 1 }
        await coordinator.stop()

        await coordinator.start(process: Self.process)

        #expect(transcriptCountsAtConfiguration == [0, 0])
        #expect(store.confirmedUtterances.isEmpty)
        #expect(coordinator.state == .live)
        await coordinator.clearAndClose()
    }

    @Test("PCM 回调只进入有界队列且完整报告满载丢弃数")
    @MainActor func reportsDroppedPCMChunks() async {
        let harness = Harness(bufferCapacity: 1)
        await harness.coordinator.start(process: Self.process)

        harness.capture.emit(Data([1]))
        harness.capture.emit(Data([2]))

        #expect(harness.coordinator.droppedChunkCount == 1)
        await harness.coordinator.clearAndClose()
    }

    @Test("发送任务失败会停止会议而不会等待自身形成死锁")
    @MainActor func handlesSenderFailureWithoutDeadlock() async {
        let harness = Harness()
        await harness.coordinator.start(process: Self.process)
        await harness.transcriber.failSends()

        harness.capture.emit(Data([1]))
        await waitUntil { harness.coordinator.state == .error }

        #expect(harness.capture.stopCount == 1)
        await harness.coordinator.clearAndClose()
    }

    @Test("采集停止失败后保持队列关闭并拒绝启动重叠会话")
    @MainActor func keepsQueueClosedAfterCaptureCleanupFailure() async {
        let harness = Harness(captureStopFailures: 2)
        await harness.coordinator.start(process: Self.process)

        await harness.coordinator.stop()
        harness.capture.emit(Data([9]))

        #expect(harness.coordinator.state == .error)
        #expect(harness.coordinator.droppedChunkCount == 1)

        await harness.coordinator.start(process: Self.process)

        #expect(harness.capture.startedProcessIDs == [Self.process.id])
        #expect(harness.capture.stopCount == 2)
        #expect(harness.coordinator.state == .error)
        harness.coordinator.shutdown()
    }

    @Test("应用退出同步停止采集并清空所有会议内存")
    @MainActor func shutdownClearsEverything() async {
        let harness = Harness()
        await harness.coordinator.start(process: Self.process)
        await harness.transcriber.emit(.partial(
            id: "partial",
            speakerID: "1",
            text: "临时字幕",
            startMS: 0,
            endMS: 500
        ))
        await harness.transcriber.emit(.confirmed(
            id: "confirmed",
            speakerID: "1",
            text: "最终字幕",
            startMS: 0,
            endMS: 1_000
        ))
        await waitUntil {
            harness.store.partialUtterance != nil
                && harness.store.confirmedUtterances.count == 1
        }

        harness.coordinator.shutdown()

        #expect(harness.coordinator.state == .idle)
        #expect(harness.coordinator.droppedChunkCount == 0)
        #expect(harness.store.partialUtterance == nil)
        #expect(harness.store.confirmedUtterances.isEmpty)
        #expect(harness.capture.emergencyStopCount == 1)
        await waitUntil { await harness.transcriber.cancelCount == 1 }
    }
}

private extension LiveMeetingCoordinatorTests {
    static let process = AudioProcessInfo(
        id: AudioObjectID(42),
        pid: pid_t(4_242),
        name: "Meeting",
        bundleID: "example.meeting"
    )

    static let configuration = ASRConfiguration(
        appID: "test-app",
        secretID: "test-id",
        secretKey: "test-key",
        voiceID: "test-voice"
    )

    @MainActor
    final class Harness {
        let capture: FakeLiveCapture
        let transcriber: FakeLiveTranscriber
        let store: LiveTranscriptStore
        let coordinator: LiveMeetingCoordinator

        init(
            recorder: CoordinatorOperationRecorder = CoordinatorOperationRecorder(),
            bufferCapacity: Int = 8,
            captureStopFailures: Int = 0
        ) {
            capture = FakeLiveCapture(
                recorder: recorder,
                stopFailures: captureStopFailures
            )
            transcriber = FakeLiveTranscriber(recorder: recorder)
            store = LiveTranscriptStore()
            coordinator = LiveMeetingCoordinator(
                capture: capture,
                transcriptStore: store,
                transcriberFactory: { [transcriber] in transcriber },
                configurationProvider: { LiveMeetingCoordinatorTests.configuration },
                processObserver: FakeMeetingProcessObserver(),
                bufferCapacity: bufferCapacity
            )
        }
    }

    @MainActor
    static func waitUntil(
        attempts: Int = 200,
        condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<attempts {
            if await condition() { return }
            try? await Task<Never, Never>.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Condition did not become true")
    }
}

private enum FakeAssistantError: Error {
    case unavailable
}

private enum FakeCoordinatorError: Error {
    case failed
}

private actor CoordinatorOperationRecorder {
    private(set) var operations: [String] = []

    func append(_ operation: String) {
        operations.append(operation)
    }
}

@MainActor
private final class FakeLiveCapture: LiveAudioCapturing {
    private let recorder: CoordinatorOperationRecorder
    private var sink: (@Sendable (Data) -> Void)?

    private(set) var startedProcessIDs: [AudioObjectID] = []
    private(set) var stopCount = 0
    private(set) var emergencyStopCount = 0
    private var stopFailures: Int

    init(
        recorder: CoordinatorOperationRecorder = CoordinatorOperationRecorder(),
        stopFailures: Int = 0
    ) {
        self.recorder = recorder
        self.stopFailures = stopFailures
    }

    func startLiveCapture(
        processObjectID: AudioObjectID,
        onPCM: @escaping @Sendable (Data) -> Void
    ) async throws {
        startedProcessIDs.append(processObjectID)
        sink = onPCM
        await recorder.append("capture.start")
    }

    func stopCapture() async throws {
        stopCount += 1
        await recorder.append("capture.stop")
        if stopFailures > 0 {
            stopFailures -= 1
            throw FakeCoordinatorError.failed
        }
        sink = nil
    }

    func emergencyStop() {
        emergencyStopCount += 1
        sink = nil
    }

    func emit(_ data: Data) {
        sink?(data)
    }
}

private actor FakeLiveTranscriber: LiveTranscriber, LiveTranscriberConnectionStateReporting {
    nonisolated let eventStream: AsyncThrowingStream<TranscriptEvent, Error>
    private let continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    nonisolated let connectionStateStream: AsyncStream<LiveTranscriberConnectionState>
    private let connectionStateContinuation: AsyncStream<LiveTranscriberConnectionState>.Continuation
    private let recorder: CoordinatorOperationRecorder

    private(set) var connectCount = 0
    private(set) var cancelCount = 0
    private(set) var sentPCM: [Data] = []
    private var sendsFail = false

    init(recorder: CoordinatorOperationRecorder = CoordinatorOperationRecorder()) {
        let pair = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        eventStream = pair.stream
        continuation = pair.continuation
        let statePair = AsyncStream<LiveTranscriberConnectionState>.makeStream()
        connectionStateStream = statePair.stream
        connectionStateContinuation = statePair.continuation
        self.recorder = recorder
    }

    func connect(configuration: ASRConfiguration) async throws {
        connectCount += 1
        await recorder.append("asr.connect")
        connectionStateContinuation.yield(.live)
    }

    func send(_ pcm: Data) async throws {
        if sendsFail { throw FakeCoordinatorError.failed }
        sentPCM.append(pcm)
        await recorder.append("asr.send")
    }

    nonisolated func events() -> AsyncThrowingStream<TranscriptEvent, Error> {
        eventStream
    }

    nonisolated func connectionStateUpdates() -> AsyncStream<LiveTranscriberConnectionState> {
        connectionStateStream
    }

    func finish() async {
        await recorder.append("asr.finish")
        continuation.finish()
    }

    func cancel() async {
        cancelCount += 1
        await recorder.append("asr.cancel")
        continuation.finish()
    }

    func emit(_ event: TranscriptEvent) {
        continuation.yield(event)
    }

    func fail(_ error: Error) {
        continuation.finish(throwing: error)
    }

    func emitConnectionState(_ state: LiveTranscriberConnectionState) {
        connectionStateContinuation.yield(state)
    }

    func failSends() {
        sendsFail = true
    }
}

@MainActor
private final class FakeMeetingProcessObserver: LiveMeetingProcessObserving {
    private var handler: (@MainActor @Sendable () -> Void)?

    func observeExit(
        of processID: pid_t,
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        self.handler = handler
    }

    func stopObserving() {
        handler = nil
    }

    func emitExit() {
        handler?()
    }
}
