import Foundation
import Testing
@testable import CallCapture

@Suite("TencentTranscriptDecoder")
struct TencentTranscriptDecoderTests {
    @Test("解析多句临时和最终结果并将 -1 说话人映射为未知")
    func decodesSentenceList() throws {
        let payload = Data(
            #"""
            {
              "code": 0,
              "message": "success",
              "voice_id": "redacted-voice",
              "message_id": "redacted-message",
              "sentences": {
                "sentence_list": [
                  {
                    "sentence": "方案还在讨论",
                    "sentence_type": 0,
                    "sentence_id": 7,
                    "speaker_id": -1,
                    "start_time": 120,
                    "end_time": 860
                  },
                  {
                    "sentence": "这是已确认内容",
                    "sentence_type": 1,
                    "sentence_id": 8,
                    "speaker_id": 2,
                    "start_time": 900,
                    "end_time": 1650
                  }
                ]
              }
            }
            """#.utf8
        )

        let events = try TencentTranscriptDecoder().decode(payload)

        #expect(events == [
            .partial(
                id: "7",
                speakerID: nil,
                text: "方案还在讨论",
                startMS: 120,
                endMS: 860
            ),
            .confirmed(
                id: "8",
                speakerID: "2",
                text: "这是已确认内容",
                startMS: 900,
                endMS: 1_650
            ),
        ])
    }

    @Test("服务端错误只暴露错误码且不回显原始 JSON")
    func redactsServiceErrorPayload() {
        let transcriptMarker = "private-transcript-must-not-escape"
        let payload = Data(
            #"{"code":4001,"message":"credential rejected","sentences":{"sentence_list":[{"sentence":"private-transcript-must-not-escape","sentence_type":1,"sentence_id":1,"speaker_id":0,"start_time":0,"end_time":1}]}}"#.utf8
        )

        do {
            _ = try TencentTranscriptDecoder().decode(payload)
            Issue.record("Expected a service error")
        } catch {
            #expect(error as? TencentTranscriptDecoderError == .service(code: 4_001))
            #expect(!String(describing: error).contains(transcriptMarker))
            #expect(!String(describing: error).contains("credential rejected"))
            #expect(!String(describing: error).contains(String(decoding: payload, as: UTF8.self)))
        }
    }

    @Test("损坏的事件返回固定错误而不回显原始内容")
    func redactsMalformedPayload() {
        let payload = Data(#"{"private":"raw-json-marker""#.utf8)

        do {
            _ = try TencentTranscriptDecoder().decode(payload)
            Issue.record("Expected an invalid-response error")
        } catch {
            #expect(error as? TencentTranscriptDecoderError == .invalidResponse)
            #expect(!String(describing: error).contains("raw-json-marker"))
        }
    }

    @Test("拒绝超出腾讯协议范围的说话人编号")
    func rejectsOutOfRangeSpeakerID() {
        let payload = Data(
            #"{"code":0,"sentences":{"sentence_list":[{"sentence":"redacted","sentence_type":1,"sentence_id":1,"speaker_id":10,"start_time":0,"end_time":1}]}}"#.utf8
        )

        do {
            _ = try TencentTranscriptDecoder().decode(payload)
            Issue.record("Expected an invalid-response error")
        } catch {
            #expect(error as? TencentTranscriptDecoderError == .invalidResponse)
        }
    }
}
