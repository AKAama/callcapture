import AppKit
import SwiftUI

enum RealtimeMeetingPrimaryAction: Equatable {
    case start
    case startNewMeeting
    case stop
}

/// Pure presentation derived from the coordinator's single source of truth.
struct RealtimeMeetingPresentation: Equatable {
    let state: LiveConnectionState

    var primaryAction: RealtimeMeetingPrimaryAction {
        switch state {
        case .connecting, .live, .reconnecting: .stop
        case .review: .startNewMeeting
        case .idle, .error: .start
        }
    }

    var statusText: String {
        switch state {
        case .idle: "准备就绪"
        case .connecting: "正在连接…"
        case .live: "实时字幕"
        case .reconnecting: "正在重连…"
        case .review: "字幕可查看"
        case .error: "连接已中断"
        }
    }

    var statusColor: Color {
        switch state {
        case .live: .green
        case .connecting, .reconnecting: .orange
        case .error: .red
        case .idle, .review: .secondary
        }
    }
}

enum RealtimePrivacy {
    static let notice = "所选应用音频会发送到腾讯云 ASR；只有手动提交时，最近 30 秒字幕才会发送到所配置的 LLM；内容不会保存到本地"
}

/// Compact production control surface for the memory-only realtime flow.
@available(macOS 14.2, *)
struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @State private var audioProcesses: [AudioProcessInfo] = []
    @State private var selectedProcessPID: pid_t?

    private var presentation: RealtimeMeetingPresentation {
        RealtimeMeetingPresentation(state: appModel.liveMeetingCoordinator.state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusHeader
            processPicker
            privacyNotice
            primaryButton
            qualityAndErrorStatus
            Divider()
            overlayControls
            settingsButton
            Divider()
            quitButton
        }
        .padding()
        .frame(width: 340)
        .onAppear {
            refreshAudioProcesses()
            appModel.setOpenSettingsAction(showSettings)
        }
    }
}

@available(macOS 14.2, *)
private extension ContentView {
    var statusHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: appModel.menuBarIconName)
                .font(.title2)
                .foregroundStyle(presentation.statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.statusText)
                    .font(.headline)
                Text("仅捕获所选应用，不使用麦克风")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    var processPicker: some View {
        HStack(spacing: 8) {
            if audioProcesses.isEmpty {
                Text("未发现可捕获应用")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker("会议应用", selection: $selectedProcessPID) {
                    Text("选择应用").tag(pid_t?.none)
                    ForEach(audioProcesses) { process in
                        Text(process.name).tag(pid_t?.some(process.pid))
                    }
                }
                .pickerStyle(.menu)
                .disabled(presentation.primaryAction == .stop)
            }

            Button(action: refreshAudioProcesses) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(presentation.primaryAction == .stop)
            .help("刷新可捕获应用")
        }
    }

    var privacyNotice: some View {
        Text(RealtimePrivacy.notice)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    var primaryButton: some View {
        Button {
            Task {
                switch presentation.primaryAction {
                case .stop:
                    await appModel.stopLiveMeeting()
                case .start, .startNewMeeting:
                    guard let selectedProcess else { return }
                    await appModel.startLiveMeeting(process: selectedProcess)
                }
            }
        } label: {
            Label(primaryButtonTitle, systemImage: primaryButtonIcon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(presentation.primaryAction == .stop ? .red : .accentColor)
        .disabled(presentation.primaryAction != .stop && selectedProcess == nil)
    }

    @ViewBuilder
    var qualityAndErrorStatus: some View {
        if let error = appModel.liveMeetingCoordinator.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        if appModel.liveMeetingCoordinator.droppedChunkCount > 0 {
            Label(
                "音频处理繁忙，已丢弃 \(appModel.liveMeetingCoordinator.droppedChunkCount) 个数据块。",
                systemImage: "waveform.badge.exclamationmark"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    var overlayControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                appModel.showSubtitlePanel()
            } label: {
                Label("显示字幕窗口", systemImage: "captions.bubble")
            }
            .buttonStyle(.plain)

            Button {
                appModel.showAssistantPanel(openSettings: showSettings)
            } label: {
                Label("打开会议助手", systemImage: "sparkles")
            }
            .buttonStyle(.plain)

            if appModel.subtitleMousePassthroughEnabled {
                Button {
                    appModel.setSubtitleMousePassthrough(false)
                } label: {
                    Label("解锁字幕窗口鼠标操作", systemImage: "lock.open")
                }
                .buttonStyle(.plain)
            }
        }
        .font(.subheadline)
    }

    var settingsButton: some View {
        Button(action: showSettings) {
            Label("设置", systemImage: "gear")
                .font(.subheadline)
        }
        .buttonStyle(.plain)
    }

    var quitButton: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("退出 CallCapture", systemImage: "power")
                .font(.subheadline)
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q", modifiers: .command)
    }

    var selectedProcess: AudioProcessInfo? {
        guard let selectedProcessPID else { return nil }
        return audioProcesses.first { $0.pid == selectedProcessPID }
    }

    var primaryButtonTitle: String {
        switch presentation.primaryAction {
        case .start: "开始实时字幕"
        case .startNewMeeting: "开始新会议"
        case .stop: "停止并查看字幕"
        }
    }

    var primaryButtonIcon: String {
        presentation.primaryAction == .stop ? "stop.circle.fill" : "play.circle.fill"
    }

    func refreshAudioProcesses() {
        let refreshed = AudioProcessEnumerator.processes()
        audioProcesses = refreshed
        if let selectedProcessPID,
           !refreshed.contains(where: { $0.pid == selectedProcessPID }) {
            self.selectedProcessPID = nil
        }
    }

    func showSettings() {
        openWindow(id: "settings")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
