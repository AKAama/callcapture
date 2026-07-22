import Foundation

/// Credentials and request identity for one live ASR connection.
///
/// A `voiceID` belongs to exactly one WebSocket connection. Callers must create
/// a new configuration with a fresh ID before reconnecting.
struct ASRConfiguration: Sendable {
    let appID: String
    let secretID: String
    let secretKey: String
    let voiceID: String
    let engineModelType: String

    init(
        appID: String,
        secretID: String,
        secretKey: String,
        voiceID: String,
        engineModelType: String = "16k_zh_en_speaker"
    ) {
        self.appID = appID
        self.secretID = secretID
        self.secretKey = secretKey
        self.voiceID = voiceID
        self.engineModelType = engineModelType
    }
}

/// Provider-neutral interface for a live speech-to-text connection.
enum LiveTranscriberSendResult: Equatable, Sendable {
    case sent
    case reconnectDiscardRequired(sequence: Int, discardedChunkCount: Int)
}

protocol LiveTranscriber: Sendable {
    func connect(configuration: ASRConfiguration) async throws
    func send(_ pcm: Data) async throws -> LiveTranscriberSendResult
    func reconnectDiscardStatus() async -> LiveTranscriberSendResult?
    func acknowledgeReconnectDiscard(sequence: Int) async -> Int
    func events() -> AsyncThrowingStream<TranscriptEvent, Error>
    func finish() async
    func cancel() async
}
