import Foundation

enum TencentTranscriptDecoderError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case invalidResponse
    case service(code: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Tencent ASR returned an invalid response."
        case let .service(code):
            "Tencent ASR returned service error code \(code)."
        }
    }

    var description: String { errorDescription ?? "Tencent ASR error." }
}

/// Converts Tencent speaker-mode response frames into provider-neutral events.
///
/// Decode failures deliberately discard the source payload so transcript text
/// can never be propagated through an error description.
struct TencentTranscriptDecoder: Sendable {
    func decode(_ data: Data) throws -> [TranscriptEvent] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw TencentTranscriptDecoderError.invalidResponse
        }

        guard response.code == 0 else {
            throw TencentTranscriptDecoderError.service(code: response.code)
        }

        guard let items = response.sentences?.sentenceList else { return [] }

        return try items.map { item in
            guard item.sentenceID >= 0,
                  (-1...9).contains(item.speakerID),
                  item.startTime >= 0,
                  item.endTime >= item.startTime
            else {
                throw TencentTranscriptDecoderError.invalidResponse
            }

            let speakerID = item.speakerID == -1 ? nil : String(item.speakerID)
            let id = String(item.sentenceID)

            switch item.sentenceType {
            case 0:
                return .partial(
                    id: id,
                    speakerID: speakerID,
                    text: item.sentence,
                    startMS: item.startTime,
                    endMS: item.endTime
                )
            case 1:
                return .confirmed(
                    id: id,
                    speakerID: speakerID,
                    text: item.sentence,
                    startMS: item.startTime,
                    endMS: item.endTime
                )
            default:
                throw TencentTranscriptDecoderError.invalidResponse
            }
        }
    }
}

private extension TencentTranscriptDecoder {
    struct Response: Decodable {
        let code: Int
        let sentences: SpeakerSentences?
    }

    struct SpeakerSentences: Decodable {
        let sentenceList: [Sentence]

        enum CodingKeys: String, CodingKey {
            case sentenceList = "sentence_list"
        }
    }

    struct Sentence: Decodable {
        let sentence: String
        let sentenceType: Int
        let sentenceID: Int
        let speakerID: Int
        let startTime: Int
        let endTime: Int

        enum CodingKeys: String, CodingKey {
            case sentence
            case sentenceType = "sentence_type"
            case sentenceID = "sentence_id"
            case speakerID = "speaker_id"
            case startTime = "start_time"
            case endTime = "end_time"
        }
    }
}
