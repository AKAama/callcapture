import SwiftUI
import AppKit
import OSLog

/// Main popover content displayed from the menu bar icon.
/// Shows recording status, control button, last session info,
/// and a link to the diagnostics window.
@available(macOS 14.2, *)
struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "ContentView"
    )

    /// Opens a window scene and brings the app to the foreground.
    ///
    /// A menu bar (`LSUIElement`) app is not the active application, so
    /// `openWindow` alone creates the window *behind* other apps with no
    /// focus — it looks like nothing happened. Activating fixes that.
    private func showWindow(_ id: String) {
        Self.logger.info("Opening window '\(id)'")
        openWindow(id: id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some View {
        @Bindable var appModel = appModel
        return VStack(spacing: 16) {
            statusHeader
            if appModel.state == .idle || appModel.state == .error {
                devicePickers(appModel: appModel)
            }
            recordButton
            transcriptionProgress
            lastSessionInfo
            Divider()
            sessionsButton
            settingsButton
            diagnosticsButton
            Divider()
            quitButton
        }
        .padding()
        .frame(width: 280)
        .onAppear { appModel.refreshAudioDevices() }
    }

    /// Output (speaker) and microphone selection, shown before recording.
    @ViewBuilder
    private func devicePickers(appModel: AppModel) -> some View {
        @Bindable var appModel = appModel
        VStack(spacing: 6) {
            Picker("Output", selection: $appModel.selectedOutputUID) {
                Text("System Default").tag(String?.none)
                ForEach(appModel.outputDevices) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
            Picker("Mic", selection: $appModel.selectedMicUID) {
                Text("None").tag(String?.none)
                ForEach(appModel.inputDevices) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
        }
        .pickerStyle(.menu)
        .font(.caption)
    }

    @ViewBuilder
    private var statusHeader: some View {
        HStack {
            Image(systemName: appModel.menuBarIconName)
                .font(.title2)
                .foregroundStyle(statusColor)
            Text(statusText)
                .font(.headline)
            Spacer()
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        Button {
            Task { await appModel.toggleRecording() }
        } label: {
            Label(
                appModel.state == .recording ? "Stop Recording" : "Start Recording",
                systemImage: appModel.state == .recording ? "stop.circle.fill" : "record.circle"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(appModel.state == .recording ? .red : .accentColor)
        .disabled(appModel.state == .transcribing)
    }

    @ViewBuilder
    private var lastSessionInfo: some View {
        if let title = appModel.lastSessionTitle,
           let date = appModel.lastSessionDate {
            VStack(alignment: .leading, spacing: 4) {
                Text("Last Session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline)
                // Static recorded-at time + fixed duration. Do NOT use
                // `style: .relative` here — it auto-ticks every second and
                // reads as a recording timer that never stopped.
                Text(lastSessionSubtitle(date: date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let error = appModel.lastError, appModel.state == .error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var transcriptionProgress: some View {
        if appModel.state == .transcribing {
            VStack(spacing: 8) {
                ProgressView(value: appModel.pythonBridge.progress)
                    .progressViewStyle(.linear)
                Text("Transcribing...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button(role: .cancel) {
                    appModel.cancelTranscription()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var sessionsButton: some View {
        Button {
            showWindow("sessions")
        } label: {
            Label("View Sessions", systemImage: "list.bullet.rectangle")
                .font(.subheadline)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var settingsButton: some View {
        Button {
            showWindow("settings")
        } label: {
            Label("Settings", systemImage: "gear")
                .font(.subheadline)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var diagnosticsButton: some View {
        Button {
            showWindow("diagnostics")
        } label: {
            Label("Diagnostics", systemImage: "stethoscope")
                .font(.subheadline)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var quitButton: some View {
        Button {
            Self.logger.info("Quit requested from popover")
            // Triggers applicationWillTerminate -> teardownForExit, which
            // releases audio capture and any running worker process.
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Quit CallCapture", systemImage: "power")
                .font(.subheadline)
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q", modifiers: .command)
    }

    /// Static subtitle for the last session: recorded time + fixed duration.
    private func lastSessionSubtitle(date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if let duration = appModel.lastSessionDuration {
            return "Recorded \(time) · \(formattedDuration(duration))"
        }
        return "Recorded \(time)"
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var statusColor: Color {
        switch appModel.state {
        case .idle: .secondary
        case .recording: .red
        case .transcribing: .orange
        case .error: .red
        }
    }

    private var statusText: String {
        switch appModel.state {
        case .idle: "Ready"
        case .recording: "Recording..."
        case .transcribing: "Transcribing..."
        case .error: "Error"
        }
    }
}
