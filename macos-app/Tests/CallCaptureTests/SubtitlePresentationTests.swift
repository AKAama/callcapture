import Testing
@testable import CallCapture

@Suite("Subtitle presentation")
struct SubtitlePresentationTests {
    @Test("实时展示只保留最近三条最终字幕和当前临时字幕")
    func liveShowsLatestThreeConfirmedAndPartial() {
        let confirmed = [
            utterance(id: "1", text: "第一条", startMS: 0),
            utterance(id: "2", text: "第二条", startMS: 1_000),
            utterance(id: "3", text: "第三条", startMS: 2_000),
            utterance(id: "4", text: "第四条", startMS: 3_000),
        ]
        let partial = utterance(
            id: "partial",
            text: "正在说",
            startMS: 4_000,
            isFinal: false
        )

        let presentation = SubtitlePresentation(
            state: .live,
            confirmedUtterances: confirmed,
            partialUtterance: partial
        )

        #expect(presentation.confirmedUtterances.map(\.id) == ["2", "3", "4"])
        #expect(presentation.partialUtterance?.id == "partial")
    }

    @Test("查看模式展示全部最终字幕且不展示临时字幕")
    func reviewShowsEveryConfirmedWithoutPartial() {
        let confirmed = (1...5).map {
            utterance(id: "\($0)", text: "第 \($0) 条", startMS: $0 * 1_000)
        }

        let presentation = SubtitlePresentation(
            state: .review,
            confirmedUtterances: confirmed,
            partialUtterance: utterance(
                id: "partial",
                text: "不应展示",
                startMS: 6_000,
                isFinal: false
            )
        )

        #expect(presentation.confirmedUtterances.map(\.id) == ["1", "2", "3", "4", "5"])
        #expect(presentation.partialUtterance == nil)
    }

    @Test("复制文本包含全部最终字幕但不包含临时字幕")
    func copyTextExcludesPartial() {
        let presentation = SubtitlePresentation(
            state: .live,
            confirmedUtterances: [
                utterance(id: "1", speaker: "发言人 1", text: "你好", startMS: 0),
                utterance(id: "2", speaker: "发言人 2", text: "欢迎", startMS: 1_000),
            ],
            partialUtterance: utterance(
                id: "partial",
                speaker: "发言人 1",
                text: "临时内容",
                startMS: 2_000,
                isFinal: false
            )
        )

        #expect(presentation.copyText == "发言人 1：你好\n发言人 2：欢迎")
        #expect(!presentation.copyText.contains("临时内容"))
    }
}

private func utterance(
    id: String,
    speaker: String = "发言人 1",
    text: String,
    startMS: Int,
    isFinal: Bool = true
) -> TranscriptUtterance {
    TranscriptUtterance(
        id: id,
        speakerID: "speaker",
        speakerLabel: speaker,
        text: text,
        startMS: startMS,
        endMS: startMS + 900,
        isFinal: isFinal
    )
}
