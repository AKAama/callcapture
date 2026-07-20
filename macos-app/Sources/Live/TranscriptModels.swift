/// A provider-neutral transcript update emitted while a meeting is being transcribed.
enum TranscriptEvent: Equatable, Sendable {
    case partial(id: String, speakerID: String?, text: String, startMS: Int, endMS: Int)
    case confirmed(id: String, speakerID: String?, text: String, startMS: Int, endMS: Int)
}

/// A transcript utterance kept only for the active in-memory meeting session.
struct TranscriptUtterance: Equatable, Sendable {
    let id: String
    let speakerID: String?
    let speakerLabel: String
    let text: String
    let startMS: Int
    let endMS: Int
    let isFinal: Bool
}

/// The user-visible lifecycle of a live meeting transcription session.
enum LiveConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case live
    case reconnecting
    case review
    case failed
}
