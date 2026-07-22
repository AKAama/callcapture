import Foundation
import Testing
@testable import CallCapture

@Suite("TencentSigner")
struct TencentSignerTests {
    @Test("按腾讯云规则排序参数并编码 HMAC-SHA1 Base64 签名")
    func createsDeterministicSignedURL() throws {
        let configuration = ASRConfiguration(
            appID: "1250000000",
            secretID: "AKIDEXAMPLE",
            secretKey: "tencent-test-secret-10",
            voiceID: "00000000-0000-4000-8000-000000000001"
        )

        let url = try TencentSigner().signedURL(
            configuration: configuration,
            timestamp: 1_673_408_372,
            nonce: 1_673_408_372
        )

        #expect(
            url.absoluteString ==
                "wss://asr.cloud.tencent.com/asr/v2/1250000000?" +
                "convert_num_mode=1&emotion_recognition=0&enable_speaker_context=0&" +
                "engine_model_type=16k_zh_en_speaker&expired=1673494772&" +
                "language_judgment=0&needvad=1&nonce=1673408372&" +
                "reinforce_hotword=0&result_mod=1&secretid=AKIDEXAMPLE&" +
                "sentence_strategy=1&speaker_context_id=&speaker_diarization=1&" +
                "timestamp=1673408372&voice_format=1&" +
                "voice_id=00000000-0000-4000-8000-000000000001&" +
                "signature=%2BIyW0f%2BQ%2FBb95ymaMf%2B5tKi8P38%3D"
        )
    }

    @Test("无效配置错误不回显配置值")
    func redactsInvalidConfiguration() {
        let marker = "private-value-must-not-escape"
        let configuration = ASRConfiguration(
            appID: "1250000000",
            secretID: "AKIDEXAMPLE",
            secretKey: "test-secret",
            voiceID: marker + "?"
        )

        do {
            _ = try TencentSigner().signedURL(
                configuration: configuration,
                timestamp: 1_673_408_372,
                nonce: 1
            )
            Issue.record("Expected invalid configuration")
        } catch {
            #expect(error as? TencentSignerError == .invalidConfiguration)
            #expect(!String(describing: error).contains(marker))
            #expect(!String(describing: error).contains("test-secret"))
        }
    }
}
