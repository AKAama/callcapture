import SwiftUI

/// Reusable row view for a session in the sessions list.
///
/// Displays the session title, the recorded date, formatted duration,
/// and a status badge pill.
@available(macOS 14.2, *)
struct SessionRowView: View {
    let session: Session

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    // Static recorded date. NOT `style: .relative` — that
                    // auto-ticks every second and looks like a live timer
                    // that never stops after recording ends.
                    Text(session.startedAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let duration = session.durationSec {
                        Text(formattedDuration(duration))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            if let total = CostFormat.total(session.costTranscription, session.costProcessing) {
                Text(CostFormat.usd(total))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            StatusBadge(status: session.status)
        }
        .padding(.vertical, 4)
    }

    /// Formats seconds into "Xm Ys" display string.
    private func formattedDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        if minutes > 0 {
            return "\(minutes)m \(remainingSeconds)s"
        }
        return "\(remainingSeconds)s"
    }
}
