import Foundation
import OSLog

private let analysisLogger = Logger(subsystem: "com.callcapture.app", category: "Analysis")

/// Decodable mirror of the worker's `<id>_analysis.json`. Every field is decoded
/// defensively (`decodeIfPresent` + default) so a partial, older, or future-extended
/// payload never throws; `load(fromPath:)` returns nil on any file/parse failure.

struct SpeakerSentiment: Decodable, Sendable {
    let label: String
    let score: Double

    enum CodingKeys: String, CodingKey { case label, score }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "neutral"
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
    }
}

struct ArcPoint: Decodable, Sendable {
    let t: Double
    let score: Double

    enum CodingKeys: String, CodingKey { case t, score }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decodeIfPresent(Double.self, forKey: .t) ?? 0
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
    }
}

struct Sentiment: Decodable, Sendable {
    let overall: String
    let overallScore: Double
    let bySpeaker: [String: SpeakerSentiment]
    let arc: [ArcPoint]

    enum CodingKeys: String, CodingKey {
        case overall
        case overallScore = "overall_score"
        case bySpeaker = "by_speaker"
        case arc
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overall = try c.decodeIfPresent(String.self, forKey: .overall) ?? "neutral"
        overallScore = try c.decodeIfPresent(Double.self, forKey: .overallScore) ?? 0
        bySpeaker = try c.decodeIfPresent([String: SpeakerSentiment].self, forKey: .bySpeaker) ?? [:]
        arc = try c.decodeIfPresent([ArcPoint].self, forKey: .arc) ?? []
    }
}

struct SpeakerStats: Decodable, Sendable {
    let label: String
    let isSelf: Bool
    let talkSeconds: Double
    let talkRatio: Double
    let words: Int
    let wordsPerMin: Double
    let turns: Int
    let longestMonologueSec: Double
    let dominantEmotion: String?
    let valence: Double?
    let arousal: Double?

    enum CodingKeys: String, CodingKey {
        case label
        case isSelf = "is_self"
        case talkSeconds = "talk_seconds"
        case talkRatio = "talk_ratio"
        case words
        case wordsPerMin = "words_per_min"
        case turns
        case longestMonologueSec = "longest_monologue_sec"
        case dominantEmotion = "dominant_emotion"
        case valence
        case arousal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
        talkSeconds = try c.decodeIfPresent(Double.self, forKey: .talkSeconds) ?? 0
        talkRatio = try c.decodeIfPresent(Double.self, forKey: .talkRatio) ?? 0
        words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
        wordsPerMin = try c.decodeIfPresent(Double.self, forKey: .wordsPerMin) ?? 0
        turns = try c.decodeIfPresent(Int.self, forKey: .turns) ?? 0
        longestMonologueSec = try c.decodeIfPresent(Double.self, forKey: .longestMonologueSec) ?? 0
        dominantEmotion = try c.decodeIfPresent(String.self, forKey: .dominantEmotion)
        valence = try c.decodeIfPresent(Double.self, forKey: .valence)
        arousal = try c.decodeIfPresent(Double.self, forKey: .arousal)
    }
}

struct Insights: Decodable, Sendable {
    let title: String
    let summary: String
    let keyPoints: [String]
    let actionItems: [String]
    let recommendedActions: [String]
    let dynamics: String
    let opportunities: [String]
    let reflections: [String]
    let outline: [String]
    let keyConcepts: [String]
    let qa: [String]
    let takeaways: [String]

    enum CodingKeys: String, CodingKey {
        case title, summary
        case keyPoints = "key_points"
        case actionItems = "action_items"
        case recommendedActions = "recommended_actions"
        case dynamics, opportunities, reflections, outline
        case keyConcepts = "key_concepts"
        case qa, takeaways
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        actionItems = try c.decodeIfPresent([String].self, forKey: .actionItems) ?? []
        recommendedActions = try c.decodeIfPresent([String].self, forKey: .recommendedActions) ?? []
        dynamics = try c.decodeIfPresent(String.self, forKey: .dynamics) ?? ""
        opportunities = try c.decodeIfPresent([String].self, forKey: .opportunities) ?? []
        reflections = try c.decodeIfPresent([String].self, forKey: .reflections) ?? []
        outline = try c.decodeIfPresent([String].self, forKey: .outline) ?? []
        keyConcepts = try c.decodeIfPresent([String].self, forKey: .keyConcepts) ?? []
        qa = try c.decodeIfPresent([String].self, forKey: .qa) ?? []
        takeaways = try c.decodeIfPresent([String].self, forKey: .takeaways) ?? []
    }
}

struct ConversationAnalysis: Decodable, Sendable {
    let recordingType: String
    let numSpeakers: Int
    let speakers: [SpeakerStats]
    let warnings: [String]
    let sentiment: Sentiment?
    let insights: Insights?

    enum CodingKeys: String, CodingKey {
        case recordingType = "recording_type"
        case numSpeakers = "num_speakers"
        case speakers, warnings, sentiment, insights
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordingType = try c.decodeIfPresent(String.self, forKey: .recordingType) ?? "call_meeting"
        numSpeakers = try c.decodeIfPresent(Int.self, forKey: .numSpeakers) ?? 0
        speakers = try c.decodeIfPresent([SpeakerStats].self, forKey: .speakers) ?? []
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        sentiment = try c.decodeIfPresent(Sentiment.self, forKey: .sentiment)
        insights = try c.decodeIfPresent(Insights.self, forKey: .insights)
    }

    /// True when there is anything worth showing in the insights panel.
    ///
    /// Mirrors exactly the fields `ConversationInsightsView` renders — speakers,
    /// overall sentiment, recommended actions, and action items. Insight prose
    /// (summary/dynamics/outline/…) is shown in the Markdown note, not this panel,
    /// so an insights block carrying only prose intentionally leaves this false.
    var hasContent: Bool {
        !speakers.isEmpty
            || sentiment != nil
            || !(insights?.recommendedActions.isEmpty ?? true)
            || !(insights?.actionItems.isEmpty ?? true)
    }

    /// Loads and decodes the analysis sidecar; returns nil on a missing file or
    /// unparseable JSON (logged, never thrown).
    static func load(fromPath path: String) -> ConversationAnalysis? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        do {
            return try JSONDecoder().decode(ConversationAnalysis.self, from: data)
        } catch {
            analysisLogger.error("Failed to decode analysis at \(path): \(error.localizedDescription)")
            return nil
        }
    }
}

/// Pure string formatting for the insights panel (kept out of the View so it is
/// unit-testable without SwiftUI/availability gymnastics).
enum InsightsFormat {
    /// A clamped, rounded percentage label, e.g. 0.6 -> "60%".
    static func percent(_ ratio: Double) -> String {
        let clamped = max(0, min(1, ratio))
        return "\(Int((clamped * 100).rounded()))%"
    }

    /// A signed fixed-point label, e.g. 0.5 -> "+0.50", -0.2 (1 digit) -> "-0.2".
    static func signed(_ value: Double, fractionDigits: Int = 2) -> String {
        String(format: "%+.\(fractionDigits)f", value)
    }
}
