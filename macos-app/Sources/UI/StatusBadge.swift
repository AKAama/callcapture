import SwiftUI

/// Small colored pill badge indicating session status.
///
/// Maps session status strings to a color and display label:
/// - `recording` -> red
/// - `completed` -> blue
/// - `transcribed` -> green
/// - `error` -> orange
@available(macOS 14.2, *)
struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(displayLabel)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(badgeColor, in: Capsule())
    }

    private var displayLabel: String {
        switch status {
        case "recording": "Recording"
        case "completed": "Completed"
        case "transcribed": "Transcribed"
        case "interrupted": "Interrupted"
        case "error": "Error"
        default: status.capitalized
        }
    }

    private var badgeColor: Color {
        switch status {
        case "recording": .red
        case "completed": .blue
        case "transcribed": .green
        case "interrupted": .gray
        case "error": .orange
        default: .secondary
        }
    }
}
