import Testing
@testable import CallCapture

@Suite("LiveTranscriptStore")
struct LiveTranscriptStoreTests {
    @Test("同 ID 临时字幕会被最新结果替换")
    @MainActor func replacesPartialWithSameID() {
        let store = LiveTranscriptStore()

        store.apply(.partial(id: "p", speakerID: "1", text: "第一版", startMS: 0, endMS: 1_000))
        store.apply(.partial(id: "p", speakerID: "1", text: "第二版", startMS: 0, endMS: 1_200))

        #expect(store.partialUtterance?.text == "第二版")
        #expect(store.partialUtterance?.isFinal == false)
    }

    @Test("最终字幕按 ID 只追加一次并按开始时间排序")
    @MainActor func deduplicatesAndSortsConfirmedUtterances() {
        let store = LiveTranscriptStore()

        store.apply(.confirmed(id: "later", speakerID: "1", text: "后一句", startMS: 2_000, endMS: 3_000))
        store.apply(.confirmed(id: "earlier", speakerID: "2", text: "前一句", startMS: 0, endMS: 1_000))
        store.apply(.confirmed(id: "later", speakerID: "1", text: "不应覆盖", startMS: 2_000, endMS: 3_000))

        #expect(store.confirmedUtterances.map(\.id) == ["earlier", "later"])
        #expect(store.confirmedUtterances.last?.text == "后一句")
    }

    @Test("未知说话人保留明确的本地化标签")
    @MainActor func labelsUnknownSpeaker() {
        let store = LiveTranscriptStore()

        store.apply(.confirmed(id: "unknown", speakerID: nil, text: "是谁在说话", startMS: 0, endMS: 1_000))

        #expect(store.confirmedUtterances.single?.speakerLabel == "未知发言人")
    }

    @Test("30 秒上下文只包含已确认话语并保留跨界整句")
    @MainActor func selectsContext() {
        let store = LiveTranscriptStore()
        store.apply(.confirmed(id: "old", speakerID: "1", text: "太早", startMS: 60_000, endMS: 69_999))
        store.apply(.confirmed(id: "a", speakerID: "1", text: "较早但跨界", startMS: 69_000, endMS: 71_000))
        store.apply(.partial(id: "p", speakerID: "2", text: "临时", startMS: 95_000, endMS: 99_000))
        store.apply(.confirmed(id: "b", speakerID: "2", text: "当前问题", startMS: 90_000, endMS: 100_000))
        store.apply(.confirmed(id: "future", speakerID: "2", text: "未来话语", startMS: 100_001, endMS: 101_000))

        #expect(store.context(endingAt: 100, duration: 30).map(\.id) == ["a", "b"])
    }

    @Test("当前会议时间使用注入的会话单调相对时钟")
    @MainActor func exposesMeetingRelativeTime() {
        let store = LiveTranscriptStore()
        store.beginMeeting(clock: StoreMeetingClock(elapsedTime: 10.5))
        store.apply(.confirmed(id: "a", speakerID: "1", text: "较早", startMS: 1_000, endMS: 2_000))
        store.apply(.partial(id: "p", speakerID: "2", text: "当前", startMS: 9_000, endMS: 10_500))

        #expect(store.currentMeetingTime == 10.5)
    }

    @Test("复制文本只包含已确认字幕并保留说话人标签")
    @MainActor func copiesConfirmedTextOnly() {
        let store = LiveTranscriptStore()
        store.apply(.confirmed(id: "a", speakerID: "1", text: "你好", startMS: 0, endMS: 1_000))
        store.apply(.partial(id: "p", speakerID: "2", text: "不复制", startMS: 1_000, endMS: 2_000))

        #expect(store.copyText == "发言人 1：你好")
    }

    @Test("清空会话内全部字幕和说话人映射")
    @MainActor func clearsAllInMemoryState() {
        let store = LiveTranscriptStore()
        store.apply(.confirmed(id: "a", speakerID: "speaker-a", text: "你好", startMS: 0, endMS: 1_000))
        store.apply(.partial(id: "p", speakerID: "speaker-b", text: "临时", startMS: 1_000, endMS: 2_000))

        store.clear()
        store.apply(.confirmed(id: "b", speakerID: "speaker-b", text: "新的会话", startMS: 0, endMS: 1_000))

        #expect(store.partialUtterance == nil)
        #expect(store.confirmedUtterances.map(\.id) == ["b"])
        #expect(store.confirmedUtterances.single?.speakerLabel == "发言人 1")
        #expect(store.copyText == "发言人 1：新的会话")
    }
}

private extension Collection {
    var single: Element? { count == 1 ? first : nil }
}

private struct StoreMeetingClock: MeetingSessionClock {
    let elapsedTime: TimeInterval
}
