import Observation
import SwiftUI

/// Immutable view input derived from the in-memory meeting transcript.
///
/// Keeping this selection and formatting outside SwiftUI makes the live/review
/// behavior testable without constructing a window or touching the pasteboard.
struct SubtitlePresentation: Equatable {
    let state: LiveConnectionState
    let confirmedUtterances: [TranscriptUtterance]
    let partialUtterance: TranscriptUtterance?
    let copyText: String

    init(
        state: LiveConnectionState,
        confirmedUtterances: [TranscriptUtterance],
        partialUtterance: TranscriptUtterance?
    ) {
        self.state = state
        self.confirmedUtterances = state == .review
            ? confirmedUtterances
            : Array(confirmedUtterances.suffix(3))
        self.partialUtterance = state == .review ? nil : partialUtterance
        copyText = confirmedUtterances
            .map { "\($0.speakerLabel)：\($0.text)" }
            .joined(separator: "\n")
    }
}

/// User-controlled appearance and interaction options shared with the panel.
@Observable
@MainActor
final class SubtitlePanelSettings {
    var fontSize: Double = 22
    var backgroundOpacity: Double = 0.82
    var isMousePassthrough = false
}

/// Compact live subtitles that expand into a transcript review after stopping.
@available(macOS 14.2, *)
@MainActor
struct LiveSubtitleView: View {
    let store: LiveTranscriptStore
    let coordinator: LiveMeetingCoordinator
    let settings: SubtitlePanelSettings
    let onCopy: (String) -> Void
    let onClear: () -> Void
    let onMousePassthroughChange: (Bool) -> Void

    private var presentation: SubtitlePresentation {
        SubtitlePresentation(
            state: coordinator.state,
            confirmedUtterances: store.confirmedUtterances,
            partialUtterance: store.partialUtterance
        )
    }

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 12) {
            header(presentation)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if presentation.confirmedUtterances.isEmpty,
                       presentation.partialUtterance == nil {
                        emptyState
                    } else {
                        ForEach(presentation.confirmedUtterances, id: \.id) { utterance in
                            subtitleRow(utterance)
                        }

                        if let partial = presentation.partialUtterance {
                            subtitleRow(partial)
                                .opacity(0.68)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .defaultScrollAnchor(.bottom)

            Divider()
                .overlay(.white.opacity(0.16))

            HStack(spacing: 10) {
                Image(systemName: "textformat.size.smaller")
                    .accessibilityHidden(true)
                Slider(value: $settings.fontSize, in: 14...36, step: 1)
                    .frame(maxWidth: 130)
                    .accessibilityLabel("Subtitle font size")
                Image(systemName: "textformat.size.larger")
                    .accessibilityHidden(true)

                Divider()
                    .frame(height: 18)

                Image(systemName: "circle.lefthalf.filled")
                    .accessibilityHidden(true)
                Slider(value: $settings.backgroundOpacity, in: 0.45...1, step: 0.05)
                    .frame(maxWidth: 110)
                    .accessibilityLabel("Panel opacity")

                Spacer(minLength: 4)

                Button {
                    settings.isMousePassthrough = true
                    onMousePassthroughChange(true)
                } label: {
                    Label("Lock", systemImage: "lock.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help("Lock mouse interaction. Unlock from the menu bar.")
                .accessibilityLabel("Enable mouse pass-through")
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.78))
        }
        .padding(16)
        .foregroundStyle(.white)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(settings.backgroundOpacity))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.14), lineWidth: 1)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live subtitles")
    }
}

@available(macOS 14.2, *)
@MainActor
private extension LiveSubtitleView {
    func header(_ presentation: SubtitlePresentation) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(for: presentation.state))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            Text(statusTitle(for: presentation.state))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.76))

            Spacer()

            if presentation.state == .review {
                Button {
                    onCopy(presentation.copyText)
                } label: {
                    Label("Copy transcript", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .disabled(presentation.copyText.isEmpty)
                .help("Copy confirmed transcript")

                Button(role: .destructive) {
                    onClear()
                } label: {
                    Label("Clear transcript", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help("Clear transcript and close")
            }
        }
    }

    func subtitleRow(_ utterance: TranscriptUtterance) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(utterance.speakerLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.58))

            Group {
                if presentation.state == .review {
                    subtitleText(utterance.text)
                        .textSelection(.enabled)
                } else {
                    subtitleText(utterance.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    var emptyState: some View {
        Text("Waiting for speech…")
            .font(.system(size: settings.fontSize, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.56))
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .center)
    }

    func subtitleText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: settings.fontSize, weight: .medium, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
    }

    func statusTitle(for state: LiveConnectionState) -> String {
        switch state {
        case .idle: "Subtitles"
        case .connecting: "Connecting…"
        case .live: "Live"
        case .reconnecting: "Reconnecting…"
        case .review: "Transcript review"
        case .error: "Connection interrupted"
        }
    }

    func statusColor(for state: LiveConnectionState) -> Color {
        switch state {
        case .live: .green
        case .connecting, .reconnecting: .orange
        case .error: .red
        case .idle, .review: .secondary
        }
    }
}
