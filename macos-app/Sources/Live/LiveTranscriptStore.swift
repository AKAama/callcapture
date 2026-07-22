import Foundation
import Observation

/// The sole in-memory source of transcript state for a live meeting.
///
/// This type intentionally has no persistence dependencies: transcript content and
/// speaker mappings exist only until `clear()` is called.
@Observable
@MainActor
final class LiveTranscriptStore {
    private(set) var partialUtterance: TranscriptUtterance?
    private(set) var confirmedUtterances: [TranscriptUtterance] = []
    var connectionState: LiveConnectionState = .idle

    private var confirmedByID: [String: TranscriptUtterance] = [:]
    private var labelBySpeakerID: [String: String] = [:]

    /// Latest endpoint in the provider's meeting-relative transcript timeline.
    /// Assistant windows must use this coordinate system rather than wall time.
    var currentMeetingTime: TimeInterval {
        let confirmedEndMS = confirmedUtterances.lazy.map(\.endMS).max() ?? 0
        let partialEndMS = partialUtterance?.endMS ?? 0
        return TimeInterval(max(confirmedEndMS, partialEndMS)) / 1_000
    }

    func apply(_ event: TranscriptEvent) {
        switch event {
        case let .partial(id, speakerID, text, startMS, endMS):
            partialUtterance = utterance(
                id: id,
                speakerID: speakerID,
                text: text,
                startMS: startMS,
                endMS: endMS,
                isFinal: false
            )

        case let .confirmed(id, speakerID, text, startMS, endMS):
            guard confirmedByID[id] == nil else { return }

            let confirmed = utterance(
                id: id,
                speakerID: speakerID,
                text: text,
                startMS: startMS,
                endMS: endMS,
                isFinal: true
            )
            confirmedByID[id] = confirmed
            confirmedUtterances = confirmedByID.values.sorted { $0.startMS < $1.startMS }

            if partialUtterance?.id == id {
                partialUtterance = nil
            }
        }
    }

    /// Returns final utterances whose complete interval intersects the requested window.
    func context(endingAt: TimeInterval, duration: TimeInterval) -> [TranscriptUtterance] {
        let lowerBoundMS = Int((endingAt - duration) * 1_000)
        let upperBoundMS = Int(endingAt * 1_000)
        return confirmedUtterances.filter {
            $0.endMS >= lowerBoundMS && $0.startMS <= upperBoundMS
        }
    }

    /// Full confirmed transcript, formatted for the system pasteboard.
    var copyText: String {
        confirmedUtterances
            .map { "\($0.speakerLabel)：\($0.text)" }
            .joined(separator: "\n")
    }

    /// Clears all transcript and speaker-label state for the current meeting.
    func clear() {
        partialUtterance = nil
        confirmedUtterances = []
        confirmedByID = [:]
        labelBySpeakerID = [:]
    }

    private func utterance(
        id: String,
        speakerID: String?,
        text: String,
        startMS: Int,
        endMS: Int,
        isFinal: Bool
    ) -> TranscriptUtterance {
        TranscriptUtterance(
            id: id,
            speakerID: speakerID,
            speakerLabel: label(for: speakerID),
            text: text,
            startMS: startMS,
            endMS: endMS,
            isFinal: isFinal
        )
    }

    private func label(for speakerID: String?) -> String {
        guard let speakerID, !speakerID.isEmpty, speakerID != "-1" else {
            return "未知发言人"
        }

        if let label = labelBySpeakerID[speakerID] {
            return label
        }

        let label = "发言人 \(labelBySpeakerID.count + 1)"
        labelBySpeakerID[speakerID] = label
        return label
    }
}
