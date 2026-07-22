import Foundation
import Observation

enum MeetingAssistantState: Equatable, Sendable {
    case idle
    case composing
    case generating
    case completed
    case failed
}

protocol MeetingAssistantClock: Sendable {
    var now: TimeInterval { get }
}

struct SystemMeetingAssistantClock: MeetingAssistantClock {
    var now: TimeInterval { Date().timeIntervalSince1970 }
}

protocol MeetingAssistantStreaming: Sendable {
    func stream(
        messages: [LLMMessage],
        configuration: LLMConfiguration
    ) -> AsyncThrowingStream<String, Error>
}

extension OpenAICompatibleClient: MeetingAssistantStreaming {}

enum AssistantQuickInstruction: String, CaseIterable, Identifiable, Sendable {
    case ideas
    case organize
    case risks
    case questions
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .ideas: "给出想法"
        case .organize: "组织发言"
        case .risks: "分析风险"
        case .questions: "追问问题"
        case .custom: "自定义指令"
        }
    }

    var instruction: String {
        switch self {
        case .ideas: "给出几个可行的想法"
        case .organize: "帮我组织一段可以直接说的话"
        case .risks: "分析当前方案的风险"
        case .questions: "提出值得追问的问题"
        case .custom: ""
        }
    }
}

/// Keeps one meeting-assistant interaction entirely in memory.
///
/// It has no persistence or coordinator dependency. Only `submit()` crosses
/// the network boundary, and it sends the current editable draft rather than
/// rebuilding content from the transcript store.
@Observable
@MainActor
final class MeetingAssistant {
    nonisolated static let defaultContextDuration: TimeInterval = 30

    private(set) var state: MeetingAssistantState = .idle
    private(set) var contextText = ""
    var draft = ""
    private(set) var reply = ""
    private(set) var errorMessage: String?

    @ObservationIgnored
    private let store: LiveTranscriptStore
    @ObservationIgnored
    private let client: any MeetingAssistantStreaming
    @ObservationIgnored
    private let configurationProvider: @MainActor () -> LLMConfiguration
    @ObservationIgnored
    private let clock: any MeetingAssistantClock
    @ObservationIgnored
    private let contextDuration: TimeInterval

    @ObservationIgnored
    private var requestTask: Task<Void, Never>?
    @ObservationIgnored
    private var requestGeneration = 0

    init(
        store: LiveTranscriptStore,
        client: any MeetingAssistantStreaming = OpenAICompatibleClient(),
        configurationProvider: @escaping @MainActor () -> LLMConfiguration,
        clock: any MeetingAssistantClock = SystemMeetingAssistantClock(),
        contextDuration: TimeInterval = MeetingAssistant.defaultContextDuration
    ) {
        self.store = store
        self.client = client
        self.configurationProvider = configurationProvider
        self.clock = clock
        self.contextDuration = contextDuration
    }

    /// Selects and formats confirmed context for review before any network use.
    @discardableResult
    func compose(instruction: String) -> Bool {
        invalidateCurrentRequest()
        reply = ""
        errorMessage = nil

        let utterances = store
            .context(endingAt: clock.now, duration: contextDuration)
            .sorted {
                if $0.startMS == $1.startMS { return $0.endMS < $1.endMS }
                return $0.startMS < $1.startMS
            }
        guard !utterances.isEmpty else {
            contextText = ""
            draft = ""
            state = .failed
            errorMessage = "最近 30 秒内没有已确认字幕。"
            return false
        }

        contextText = utterances
            .map { "\($0.speakerLabel)：\($0.text)" }
            .joined(separator: "\n")

        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInstruction.isEmpty {
            draft = "最近 30 秒已确认字幕：\n\(contextText)"
        } else {
            draft = "\(trimmedInstruction)\n\n最近 30 秒已确认字幕：\n\(contextText)"
        }
        state = .composing
        return true
    }

    /// Sends exactly the current draft and streams one reply in memory.
    @discardableResult
    func submit() -> Bool {
        guard !contextText.isEmpty else {
            invalidateCurrentRequest()
            state = .failed
            errorMessage = "最近 30 秒内没有已确认字幕。"
            return false
        }

        let editedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !editedDraft.isEmpty else {
            invalidateCurrentRequest()
            state = .failed
            errorMessage = "发送内容不能为空。"
            return false
        }

        invalidateCurrentRequest()
        let generation = requestGeneration
        let configuration = configurationProvider()
        var messages: [LLMMessage] = []
        let systemPrompt = configuration.systemPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemPrompt.isEmpty {
            messages.append(.init(role: .system, content: systemPrompt))
        }
        messages.append(.init(role: .user, content: editedDraft))

        reply = ""
        errorMessage = nil
        state = .generating

        let client = self.client
        requestTask = Task { [weak self] in
            do {
                let stream = client.stream(
                    messages: messages,
                    configuration: configuration
                )
                for try await chunk in stream {
                    try Task.checkCancellation()
                    guard let self, self.requestGeneration == generation else { return }
                    self.reply += chunk
                }

                try Task.checkCancellation()
                guard let self, self.requestGeneration == generation else { return }
                self.requestTask = nil
                self.state = .completed
            } catch is CancellationError {
                // Cancellation is expected when replacing, clearing, or closing.
            } catch {
                guard let self, self.requestGeneration == generation else { return }
                self.requestTask = nil
                self.errorMessage = error.localizedDescription
                self.state = .failed
            }
        }
        return true
    }

    func cancelGeneration() {
        guard state == .generating else { return }
        invalidateCurrentRequest()
        state = .composing
        errorMessage = nil
    }

    /// Cancels all assistant work and erases every transcript-derived value.
    func clear() {
        invalidateCurrentRequest()
        contextText = ""
        draft = ""
        reply = ""
        errorMessage = nil
        state = .idle
    }

    private func invalidateCurrentRequest() {
        requestGeneration += 1
        requestTask?.cancel()
        requestTask = nil
    }
}
