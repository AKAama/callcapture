import Carbon
import CoreAudio
import Foundation
import Testing
@testable import CallCapture

@Suite("30-second meeting assistant")
struct MeetingAssistantTests {
    @Test("production composition uses the transcript meeting-relative endpoint")
    @MainActor func composesWithProductionTimebase() {
        let store = populatedStore()
        let assistant = MeetingAssistant(
            store: store,
            client: RecordingMeetingAssistantClient(),
            configurationProvider: { Self.configuration }
        )

        #expect(assistant.compose(instruction: "给出想法"))
        #expect(assistant.contextText == "发言人 1：original-transcript-marker")
    }

    @Test("default composition selects exactly 30 seconds in chronological speaker-labelled form")
    @MainActor func composesDefaultContext() throws {
        let store = LiveTranscriptStore()
        store.apply(.confirmed(
            id: "inside-later",
            speakerID: "speaker-b",
            text: "后一句",
            startMS: 95_000,
            endMS: 99_000
        ))
        store.apply(.confirmed(
            id: "outside",
            speakerID: "speaker-a",
            text: "不应发送",
            startMS: 60_000,
            endMS: 69_999
        ))
        store.apply(.confirmed(
            id: "boundary-earlier",
            speakerID: "speaker-a",
            text: "跨越边界",
            startMS: 69_000,
            endMS: 70_000
        ))
        let client = RecordingMeetingAssistantClient()
        let assistant = MeetingAssistant(
            store: store,
            client: client,
            configurationProvider: { Self.configuration },
            clock: FixedMeetingAssistantClock(now: 100)
        )

        let composed = assistant.compose(instruction: "给出想法")

        #expect(composed)
        #expect(assistant.state == .composing)
        #expect(assistant.contextText == "发言人 2：跨越边界\n发言人 1：后一句")
        #expect(assistant.draft.contains("给出想法"))
        #expect(assistant.draft.contains("发言人 2：跨越边界\n发言人 1：后一句"))
        #expect(!assistant.draft.contains("不应发送"))
    }

    @Test("only the replacement edit enters the network request")
    @MainActor func sendsOnlyEditedDraft() async throws {
        let store = populatedStore()
        let client = RecordingMeetingAssistantClient(chunks: ["建议", "内容"])
        let assistant = MeetingAssistant(
            store: store,
            client: client,
            configurationProvider: { Self.configuration },
            clock: FixedMeetingAssistantClock(now: 100)
        )
        #expect(assistant.compose(instruction: "original-instruction-marker"))
        assistant.draft = "replacement-edit-marker"

        #expect(assistant.submit())
        await waitUntil { assistant.state == .completed }

        let request = try #require(client.requests.single)
        #expect(request.messages == [
            LLMMessage(role: .system, content: Self.configuration.systemPrompt),
            LLMMessage(role: .user, content: "replacement-edit-marker"),
        ])
        #expect(!request.messages.contains { $0.content.contains("original-transcript-marker") })
        #expect(!request.messages.contains { $0.content.contains("original-instruction-marker") })
        #expect(assistant.reply == "建议内容")
    }

    @Test("empty confirmed context refuses the request without touching the client")
    @MainActor func refusesEmptyContext() {
        let store = LiveTranscriptStore()
        store.apply(.partial(
            id: "partial",
            speakerID: "1",
            text: "partial-private-marker",
            startMS: 95_000,
            endMS: 99_000
        ))
        let client = RecordingMeetingAssistantClient()
        let assistant = MeetingAssistant(
            store: store,
            client: client,
            configurationProvider: { Self.configuration },
            clock: FixedMeetingAssistantClock(now: 100)
        )

        #expect(!assistant.compose(instruction: "给出想法"))
        #expect(!assistant.submit())
        #expect(assistant.state == .failed)
        #expect(assistant.contextText.isEmpty)
        #expect(assistant.draft.isEmpty)
        #expect(client.requests.isEmpty)
    }

    @Test("a new request cancels the old stream and stale output cannot win")
    @MainActor func replacesActiveRequest() async throws {
        let client = ControlledMeetingAssistantClient()
        let assistant = MeetingAssistant(
            store: populatedStore(),
            client: client,
            configurationProvider: { Self.configuration },
            clock: FixedMeetingAssistantClock(now: 100)
        )
        #expect(assistant.compose(instruction: "first"))
        assistant.draft = "first-edit"
        #expect(assistant.submit())
        await waitUntil { client.requestCount == 1 }

        assistant.draft = "second-edit"
        #expect(assistant.submit())
        await waitUntil { client.requestCount == 2 && client.cancellationCount == 1 }

        client.yield("stale", to: 0)
        client.finish(0)
        client.yield("fresh", to: 1)
        client.finish(1)
        await waitUntil { assistant.state == .completed }

        #expect(assistant.reply == "fresh")
        #expect(client.requests.map { $0.messages.last?.content } == ["first-edit", "second-edit"])
    }

    @Test("clear cancels generation and wipes every assistant content field")
    @MainActor func clearsAllAssistantMemory() async {
        let client = ControlledMeetingAssistantClient()
        let assistant = MeetingAssistant(
            store: populatedStore(),
            client: client,
            configurationProvider: { Self.configuration },
            clock: FixedMeetingAssistantClock(now: 100)
        )
        #expect(assistant.compose(instruction: "分析风险"))
        #expect(assistant.submit())
        await waitUntil { client.requestCount == 1 }
        client.yield("private-reply-marker", to: 0)
        await waitUntil { assistant.reply == "private-reply-marker" }

        assistant.clear()
        await waitUntil { client.cancellationCount == 1 }

        #expect(assistant.state == .idle)
        #expect(assistant.contextText.isEmpty)
        #expect(assistant.draft.isEmpty)
        #expect(assistant.reply.isEmpty)
        #expect(assistant.errorMessage == nil)
    }

    @Test("clear before task startup prevents crossing the client stream boundary")
    @MainActor func clearBeforeTaskStartupPreventsStream() async {
        let client = RecordingMeetingAssistantClient()
        let assistant = MeetingAssistant(
            store: populatedStore(),
            client: client,
            configurationProvider: { Self.configuration },
            clock: FixedMeetingAssistantClock(now: 100)
        )
        #expect(assistant.compose(instruction: "分析风险"))
        #expect(assistant.submit())

        assistant.clear()
        await Task.yield()

        #expect(client.requests.isEmpty)
        #expect(assistant.state == .idle)
    }

    @Test("replacement before task startup sends only the newest request")
    @MainActor func replacementBeforeTaskStartupPreventsStaleStream() async {
        let client = RecordingMeetingAssistantClient()
        let assistant = MeetingAssistant(
            store: populatedStore(),
            client: client,
            configurationProvider: { Self.configuration },
            clock: FixedMeetingAssistantClock(now: 100)
        )
        #expect(assistant.compose(instruction: "first"))
        assistant.draft = "first-edit"
        #expect(assistant.submit())

        assistant.draft = "second-edit"
        #expect(assistant.submit())
        await waitUntil { client.requests.count == 1 && assistant.state == .completed }

        #expect(client.requests.single?.messages.last?.content == "second-edit")
    }

    @Test("a current stream cancellation returns to composing")
    @MainActor func handlesCurrentStreamCancellation() async {
        let client = RecordingMeetingAssistantClient(error: CancellationError())
        let assistant = MeetingAssistant(
            store: populatedStore(),
            client: client,
            configurationProvider: { Self.configuration },
            clock: FixedMeetingAssistantClock(now: 100)
        )
        #expect(assistant.compose(instruction: "追问问题"))
        #expect(assistant.submit())

        await waitUntil { assistant.state != .generating }

        #expect(assistant.state == .composing)
        #expect(assistant.errorMessage == nil)
    }

    @Test("LLM failure remains isolated from the live coordinator")
    @MainActor func isolatesFailureFromLiveCoordinator() async {
        let store = populatedStore()
        let capture = AssistantTestCapture()
        let transcriber = AssistantTestTranscriber()
        let coordinator = LiveMeetingCoordinator(
            capture: capture,
            transcriptStore: store,
            transcriberFactory: { transcriber },
            configurationProvider: {
                ASRConfiguration(
                    appID: "app",
                    secretID: "id",
                    secretKey: "key",
                    voiceID: "voice"
                )
            },
            processObserver: AssistantTestProcessObserver()
        )
        await coordinator.start(process: AudioProcessInfo(
            id: AudioObjectID(42),
            pid: pid_t(4_242),
            name: "Meeting",
            bundleID: "example.meeting"
        ))
        #expect(coordinator.state == .live)

        let client = RecordingMeetingAssistantClient(error: AssistantTestError.unavailable)
        let assistant = MeetingAssistant(
            store: store,
            client: client,
            configurationProvider: { Self.configuration },
            clock: FixedMeetingAssistantClock(now: 100)
        )
        #expect(assistant.compose(instruction: "分析风险"))
        #expect(assistant.submit())
        await waitUntil { assistant.state == .failed }

        #expect(coordinator.state == .live)
        #expect(capture.stopCount == 0)
        #expect(store.confirmedUtterances.map(\.text) == ["original-transcript-marker"])
        await coordinator.clearAndClose()
    }

    @Test("quick instructions and shortcut defaults remain stable")
    func exposesRequiredActionsAndDefaultShortcut() {
        #expect(AssistantQuickInstruction.allCases.map(\.title) == [
            "给出想法", "组织发言", "分析风险", "追问问题", "自定义指令",
        ])
        #expect(GlobalShortcutManager.defaultKeyCode == UInt32(kVK_Space))
        #expect(GlobalShortcutManager.defaultModifiers == UInt32(optionKey))
    }
}

private extension MeetingAssistantTests {
    static let configuration = LLMConfiguration(
        preset: .ollama,
        baseURL: "http://localhost:11434/v1",
        model: "test-model",
        apiKey: "",
        timeout: 5,
        maxTokens: 100,
        temperature: 0,
        systemPrompt: "system-prompt-marker",
        contextDuration: 99
    )

    @MainActor
    static func populatedStore() -> LiveTranscriptStore {
        let store = LiveTranscriptStore()
        store.apply(.confirmed(
            id: "context",
            speakerID: "1",
            text: "original-transcript-marker",
            startMS: 90_000,
            endMS: 99_000
        ))
        return store
    }

    @MainActor
    static func waitUntil(
        attempts: Int = 300,
        condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task<Never, Never>.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Condition did not become true")
    }
}

private struct FixedMeetingAssistantClock: MeetingAssistantClock {
    let now: TimeInterval
}

private struct RecordedAssistantRequest: Sendable {
    let messages: [LLMMessage]
    let configuration: LLMConfiguration
}

private final class RecordingMeetingAssistantClient: MeetingAssistantStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [RecordedAssistantRequest] = []
    private let chunks: [String]
    private let error: Error?

    init(chunks: [String] = [], error: Error? = nil) {
        self.chunks = chunks
        self.error = error
    }

    var requests: [RecordedAssistantRequest] {
        lock.withLock { storedRequests }
    }

    func stream(
        messages: [LLMMessage],
        configuration: LLMConfiguration
    ) -> AsyncThrowingStream<String, Error> {
        lock.withLock {
            storedRequests.append(.init(messages: messages, configuration: configuration))
        }
        return AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private final class ControlledMeetingAssistantClient: MeetingAssistantStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [RecordedAssistantRequest] = []
    private var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []
    private var storedCancellationCount = 0

    var requests: [RecordedAssistantRequest] { lock.withLock { storedRequests } }
    var requestCount: Int { lock.withLock { storedRequests.count } }
    var cancellationCount: Int { lock.withLock { storedCancellationCount } }

    func stream(
        messages: [LLMMessage],
        configuration: LLMConfiguration
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let index = lock.withLock { () -> Int in
                storedRequests.append(.init(messages: messages, configuration: configuration))
                continuations.append(continuation)
                return continuations.count - 1
            }
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination else { return }
                self?.lock.withLock { self?.storedCancellationCount += 1 }
            }
            _ = index
        }
    }

    func yield(_ chunk: String, to index: Int) {
        lock.withLock { continuations[index] }.yield(chunk)
    }

    func finish(_ index: Int) {
        lock.withLock { continuations[index] }.finish()
    }
}

private enum AssistantTestError: Error {
    case unavailable
}

@MainActor
private final class AssistantTestCapture: LiveAudioCapturing {
    private(set) var hasPendingCaptureResources = false
    private(set) var stopCount = 0

    func startLiveCapture(
        processObjectID: AudioObjectID,
        onPCM: @escaping @Sendable (Data) -> Void
    ) async throws {
        hasPendingCaptureResources = true
    }

    func stopCapture() async throws {
        stopCount += 1
        hasPendingCaptureResources = false
    }

    func emergencyStop() {
        hasPendingCaptureResources = false
    }
}

private actor AssistantTestTranscriber: LiveTranscriber {
    private let eventStream: AsyncThrowingStream<TranscriptEvent, Error>
    private let continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation

    init() {
        var continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation!
        eventStream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect(configuration: ASRConfiguration) async throws {}
    func send(_ pcm: Data) async throws {}
    nonisolated func events() -> AsyncThrowingStream<TranscriptEvent, Error> { eventStream }
    func finish() async { continuation.finish() }
    func cancel() async { continuation.finish() }
}

@MainActor
private final class AssistantTestProcessObserver: LiveMeetingProcessObserving {
    func observeExit(
        of processID: pid_t,
        handler: @escaping @MainActor @Sendable () -> Void
    ) {}

    func stopObserving() {}
}

private extension Collection {
    var single: Element? { count == 1 ? first : nil }
}
