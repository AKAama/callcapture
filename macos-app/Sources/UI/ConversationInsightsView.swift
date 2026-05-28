import SwiftUI

/// Structured rendering of a decoded `ConversationAnalysis`: per-speaker talk-ratio
/// bars with sentiment/emotion, plus recommended actions and action items. The rich
/// per-type prose stays in the Markdown note preview.
@available(macOS 14.2, *)
struct ConversationInsightsView: View {
    let analysis: ConversationAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let sentiment = analysis.sentiment {
                HStack {
                    Text("Overall: \(sentiment.overall) (\(InsightsFormat.signed(sentiment.overallScore)))")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Text("\(analysis.speakers.count) speaker\(analysis.speakers.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if sentiment.arc.count > 1 {
                    ArcSparkline(arc: sentiment.arc)
                }
            }

            ForEach(analysis.speakers, id: \.label) { speaker in
                speakerRow(speaker)
            }

            if let insights = analysis.insights {
                if !insights.recommendedActions.isEmpty {
                    actionBlock("Recommended actions", insights.recommendedActions, checkbox: false)
                }
                if !insights.actionItems.isEmpty {
                    actionBlock("Action items", insights.actionItems, checkbox: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func speakerRow(_ speaker: SpeakerStats) -> some View {
        HStack(spacing: 8) {
            Text(speaker.label)
                .font(.caption)
                .fontWeight(speaker.isSelf ? .semibold : .regular)
                .frame(width: 90, alignment: .leading)
                .lineLimit(1)

            ProgressView(value: max(0, min(1, speaker.talkRatio)))
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity)

            Text(InsightsFormat.percent(speaker.talkRatio))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)

            if let emotion = speaker.dominantEmotion {
                Text(emotion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                    .lineLimit(1)
                if let valence = speaker.valence {
                    Text(InsightsFormat.signed(valence, fractionDigits: 1))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func actionBlock(_ title: String, _ items: [String], checkbox: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            ForEach(items, id: \.self) { item in
                Label {
                    Text(item).font(.caption)
                } icon: {
                    Image(systemName: checkbox ? "square" : "circle.fill")
                        .font(.system(size: checkbox ? 10 : 6))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Thin sparkline of acoustic-valence over time. The dashed midline is neutral
/// (score 0); the line traces valence in [-1, 1] across the recording duration.
@available(macOS 14.2, *)
private struct ArcSparkline: View {
    let arc: [ArcPoint]

    var body: some View {
        Canvas { context, size in
            guard arc.count > 1 else { return }
            let tMin = arc.first!.t
            let tMax = arc.last!.t
            let tRange = max(tMax - tMin, 0.001)

            func point(_ p: ArcPoint) -> CGPoint {
                let x = (p.t - tMin) / tRange * size.width
                let clamped = max(-1, min(1, p.score))
                // Map score -1..1 to y = bottom..top (flip the SwiftUI axis).
                let y = (1 - (clamped + 1) / 2) * size.height
                return CGPoint(x: x, y: y)
            }

            // Neutral baseline.
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height / 2))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(
                baseline,
                with: .color(.secondary.opacity(0.3)),
                style: StrokeStyle(lineWidth: 0.5, dash: [2, 2])
            )

            // Arc line.
            var line = Path()
            line.move(to: point(arc[0]))
            for p in arc.dropFirst() {
                line.addLine(to: point(p))
            }
            context.stroke(line, with: .color(.accentColor), lineWidth: 1.5)
        }
        .frame(height: 28)
        .accessibilityLabel("Emotional arc over time")
    }
}
