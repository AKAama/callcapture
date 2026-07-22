import SwiftUI

/// Settings view for configuring transcription, post-processing,
/// speaker options, and export paths.
@available(macOS 14.2, *)
struct SettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.settingsManager
        Form {
            realtimeASRSection(settings: settings)
            meetingAssistantSection(settings: settings)
            assistantShortcutSection(settings: settings)
            realtimePrivacySection
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 520)
        .navigationTitle("Settings")
    }

    // MARK: - Sections

    @ViewBuilder
    private func realtimeASRSection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings
        Section("腾讯云实时字幕") {
            SecureField("App ID", text: $settings.tencentASRAppID)
            SecureField("Secret ID", text: $settings.tencentASRSecretID)
            SecureField("Secret Key", text: $settings.tencentASRSecretKey)
            Text("凭证保存在 macOS Keychain。每场会议只会把所选应用的内存音频流发送到腾讯云 ASR。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func transcriptionSection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings
        Section("Transcription Engine") {
            Picker("Engine", selection: $settings.defaultEngine) {
                ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }

            if settings.defaultEngine == .localWhisper {
                Picker("Whisper Model", selection: $settings.whisperModel) {
                    ForEach(WhisperModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
            }

            if settings.defaultEngine == .remote {
                Picker("Provider", selection: $settings.remoteProvider) {
                    ForEach(RemoteProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
            }
        }
    }

    /// Per-provider key fields shown inside the "API Keys" section when the
    /// default transcription engine is remote. AssemblyAI + Deepgram get their
    /// own dedicated fields so the `.auto` provider has both available; Groq /
    /// OpenAI fall back to the single legacy `remoteApiKey`.
    @ViewBuilder
    private func remoteKeyFields(settings: SettingsManager) -> some View {
        @Bindable var settings = settings
        switch settings.remoteProvider {
        case .auto:
            SecureField("AssemblyAI API Key", text: $settings.assemblyAIApiKey)
            SecureField("Deepgram API Key", text: $settings.deepgramApiKey)
            Text("Routes per recording by language: English / Spanish / French / German / Italian / Portuguese / Dutch / Japanese / Chinese / Korean / Hindi → AssemblyAI. Ukrainian / Russian / Polish / Czech / Swedish / Turkish / Arabic → Deepgram.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .assemblyai:
            SecureField("AssemblyAI API Key", text: $settings.assemblyAIApiKey)
            Text("Provides diarization, sentiment, summaries and topics for English-supported languages; falls back to nano (text only) for others.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .deepgram:
            SecureField("Deepgram API Key", text: $settings.deepgramApiKey)
            Text("Nova-3 covers ~36 languages with diarization + sentiment in one sync call.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .groq, .openai:
            SecureField("\(settings.remoteProvider.shortName) API Key", text: $settings.remoteApiKey)
        }
    }

    @ViewBuilder
    private func apiKeysSection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings
        Section("API Keys") {
            if settings.llmProvider == .openrouter {
                SecureField("OpenRouter API Key", text: $settings.openRouterApiKey)
                OpenRouterTestRow(apiKey: settings.openRouterApiKey)
            }

            if settings.defaultEngine == .remote {
                remoteKeyFields(settings: settings)
            }

            if settings.defaultEngine != .remote && settings.llmProvider == .local {
                Text("No API keys required for current configuration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func postProcessingSection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings
        Section("Post-Processing") {
            Picker("LLM Provider", selection: $settings.llmProvider) {
                ForEach(LLMProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            LLMModelPickerRow(slug: $settings.llmModel)

            if settings.llmProvider == .local {
                TextField("Local LLM Base URL", text: $settings.localLLMBaseURL)
                    .textFieldStyle(.roundedBorder)
                Text("Run a model in Ollama, e.g. `ollama run qwen2.5:32b`, then set Model to its id.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Markdown Profile", selection: $settings.markdownProfile) {
                ForEach(MarkdownProfile.allCases, id: \.self) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }

            Toggle("Auto-process on stop", isOn: $settings.autoProcessOnStop)
        }
    }

    @ViewBuilder
    private func meetingAssistantSection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings
        Section("Meeting Assistant") {
            Picker("Provider", selection: $settings.assistantLLMPreset) {
                ForEach(LLMProviderPreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .onChange(of: settings.assistantLLMPreset) { _, preset in
                settings.applyAssistantLLMPreset(preset)
            }

            TextField("Base URL", text: $settings.assistantLLMBaseURL)
                .textFieldStyle(.roundedBorder)
            TextField("Model", text: $settings.assistantLLMModel)
                .textFieldStyle(.roundedBorder)
            SecureField(
                settings.assistantLLMPreset.requiresAPIKey ? "API Key" : "API Key (optional)",
                text: $settings.assistantLLMAPIKey
            )
            Text("The API key is stored in macOS Keychain. Local providers may leave it blank.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Timeout (seconds)") {
                TextField("30", value: $settings.assistantLLMTimeout, format: .number)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Maximum output tokens") {
                TextField("600", value: $settings.assistantLLMMaxTokens, format: .number)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Temperature") {
                TextField("0.3", value: $settings.assistantLLMTemperature, format: .number)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Transcript context") {
                Text("30 seconds")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Default system prompt")
                TextEditor(text: $settings.assistantSystemPrompt)
                    .font(.body)
                    .frame(minHeight: 72)
                Text("Prompt text stays in memory and is cleared when the app exits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AssistantLLMConnectionTestRow(configuration: settings.assistantLLMConfiguration)
        }
    }

    @ViewBuilder
    private func assistantShortcutSection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings
        Section("助手快捷键") {
            Toggle("启用全局快捷键", isOn: $settings.assistantShortcutEnabled)
                .onChange(of: settings.assistantShortcutEnabled) { _, _ in
                    appModel.reconfigureAssistantShortcut()
                }

            Picker("快捷键", selection: $settings.assistantShortcutPreset) {
                ForEach(AssistantShortcutPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .disabled(!settings.assistantShortcutEnabled)
            .onChange(of: settings.assistantShortcutPreset) { _, _ in
                appModel.reconfigureAssistantShortcut()
            }

            Text("默认使用 ⌥Space。重新配置或关闭此选项时，旧快捷键会立即注销。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = appModel.assistantShortcutError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var realtimePrivacySection: some View {
        Section("隐私") {
            Text(RealtimePrivacy.notice)
                .font(.caption)
            Text("字幕、发送内容和模型回复只保存在内存中；开始新会议、清空字幕或退出应用时会清除。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func pricingSection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings
        Section("Pricing (USD)") {
            LabeledContent("AssemblyAI $/min") {
                TextField("0.0035", value: $settings.sttRateAssemblyAI, format: .number)
                    .frame(width: 90).multilineTextAlignment(.trailing)
            }
            LabeledContent("Deepgram $/min") {
                TextField("0.0043", value: $settings.sttRateDeepgram, format: .number)
                    .frame(width: 90).multilineTextAlignment(.trailing)
            }
            LabeledContent("OpenAI $/min") {
                TextField("0.0060", value: $settings.sttRateOpenAI, format: .number)
                    .frame(width: 90).multilineTextAlignment(.trailing)
            }
            LabeledContent("Groq $/min") {
                TextField("0.0007", value: $settings.sttRateGroq, format: .number)
                    .frame(width: 90).multilineTextAlignment(.trailing)
            }
            LabeledContent("Local Whisper") {
                Text("$0.00").foregroundStyle(.secondary)
            }
            LabeledContent("LLM fallback $/1M tokens") {
                TextField("3.00", value: $settings.llmFallbackRatePer1M, format: .number)
                    .frame(width: 90).multilineTextAlignment(.trailing)
            }
            Text("OpenRouter reports actual cost; the fallback rate is used only when it can't.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Reset to defaults") { settings.resetPricingToDefaults() }
        }
    }

    @ViewBuilder
    private func speakerSection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings
        Section("Speaker Diarization") {
            DiarizationModelsRow(
                service: appModel.diarizationService,
                modelsReady: $settings.diarizationModelsReady
            )
            EmotionModelsRow(
                bridge: appModel.pythonBridge,
                modelsReady: $settings.emotionModelsReady
            )
            Toggle("Keep separate mic track", isOn: $settings.keepSeparateMicTrack)
        }
    }

    @ViewBuilder
    private func exportSection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings
        Section("Export") {
            DirectoryPickerRow(
                label: "Output Directory",
                path: $settings.outputDirectory
            )

            DirectoryPickerRow(
                label: "Obsidian Vault",
                path: $settings.obsidianExportDirectory
            )

            TextField("Obsidian Folder Pattern", text: $settings.obsidianFolderPattern)
                .textFieldStyle(.roundedBorder)
        }
    }
}

/// A labeled row with a text field showing the current directory path
/// and a button to open a folder chooser panel.
private struct DirectoryPickerRow: View {
    let label: String
    @Binding var path: String

    var body: some View {
        LabeledContent(label) {
            HStack {
                Text(path.isEmpty ? "Not set" : abbreviatePath(path))
                    .font(.caption)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Choose...") {
                    chooseDirectory()
                }
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }

    private func abbreviatePath(_ fullPath: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if fullPath.hasPrefix(home) {
            return "~" + fullPath.dropFirst(home.count)
        }
        return fullPath
    }
}

/// Shows acoustic-emotion model status and a download button. The model lives in the
/// Python worker, so the download runs the `prepare_emotion` worker command via the bridge.
@available(macOS 14.2, *)
private struct EmotionModelsRow: View {
    let bridge: PythonBridge
    @Binding var modelsReady: Bool

    @State private var isDownloading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Emotion model")
                Spacer()
                statusLabel
            }
            Button(isDownloading ? "Downloading…" : "Download emotion model") {
                download()
            }
            .disabled(isDownloading || modelsReady)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            Text("Adds per-speaker emotion (valence/arousal) and an emotional arc. Large one-time download (~1 GB); analysis still runs without it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if isDownloading {
            Text("Downloading…").font(.caption).foregroundStyle(.secondary)
        } else if modelsReady {
            Text("Ready").font(.caption).foregroundStyle(.green)
        } else {
            Text("Not downloaded").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func download() {
        isDownloading = true
        errorMessage = nil
        Task {
            do {
                let result = try await bridge.runJob(request: .prepareEmotion())
                if result.status == "completed" {
                    modelsReady = true
                } else {
                    errorMessage = result.errorMessage ?? "Download failed"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isDownloading = false
        }
    }
}

/// Shows diarization-model status and an explicit download button. Diarization
/// only runs once models are downloaded (see DiarizationService gating).
@available(macOS 14.2, *)
private struct DiarizationModelsRow: View {
    let service: DiarizationService
    @Binding var modelsReady: Bool

    @State private var isDownloading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Models")
                Spacer()
                statusLabel
            }
            Button(isDownloading ? "Downloading…" : "Download diarization models") {
                download()
            }
            .disabled(isDownloading || modelsReady)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("Required to separate speakers in Call/Meeting recordings. Downloads once (~tens of MB); recordings still produce notes without it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if isDownloading {
            Text("Downloading…").font(.caption).foregroundStyle(.secondary)
        } else if modelsReady {
            Text("Ready").font(.caption).foregroundStyle(.green)
        } else {
            Text("Not downloaded").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func download() {
        isDownloading = true
        errorMessage = nil
        Task {
            do {
                try await service.prepareModels()
                modelsReady = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isDownloading = false
        }
    }
}

/// "Test Connection" against the configured OpenRouter key. Calls `/auth/key`
/// and renders the result inline so the user can sanity-check before recording.
@available(macOS 14.2, *)
private struct OpenRouterTestRow: View {
    let apiKey: String

    private enum Status: Equatable {
        case idle
        case testing
        case ok(summary: String)
        case failed(message: String)
    }

    @State private var status: Status = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Test Connection") {
                    Task { await runCheck() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || status == .testing)

                if status == .testing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            switch status {
            case .idle:
                EmptyView()
            case .testing:
                Text("Calling openrouter.ai/auth/key…")
                    .font(.caption).foregroundStyle(.secondary)
            case .ok(let summary):
                Label(summary, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: apiKey) { _, _ in status = .idle }
    }

    private func runCheck() async {
        status = .testing
        do {
            let info = try await OpenRouterClient().validate(apiKey: apiKey)
            status = .ok(summary: info.summary)
        } catch {
            status = .failed(message: (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription)
        }
    }
}

/// Uses a fixed, transcript-free probe against the configured Chat Completions endpoint.
@available(macOS 14.2, *)
private struct AssistantLLMConnectionTestRow: View {
    let configuration: LLMConfiguration
    @State private var tester = AssistantLLMConnectionTester()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Test Assistant Connection") {
                    tester.start(configuration: configuration)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(configuration.validationError != nil || tester.status == .testing)

                if tester.status == .testing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            switch tester.status {
            case .idle:
                if let error = configuration.validationError {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            case .testing:
                Text("Sending a fixed, transcript-free probe…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: configuration) { _, _ in tester.reset() }
        .onDisappear { tester.reset() }
    }
}

/// Owns and generations connection probes so superseded work cannot publish UI state.
@MainActor
@Observable
final class AssistantLLMConnectionTester {
    enum Status: Equatable {
        case idle
        case testing
        case connected
        case failed(String)
    }

    typealias Probe = @Sendable (LLMConfiguration) async throws -> String

    private(set) var status: Status = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let probe: Probe

    init(probe: @escaping Probe = { configuration in
        try await OpenAICompatibleClient().testConnection(configuration: configuration)
    }) {
        self.probe = probe
    }

    func start(configuration: LLMConfiguration) {
        generation &+= 1
        let currentGeneration = generation
        task?.cancel()
        status = .testing
        let probe = probe
        task = Task { [weak self] in
            do {
                _ = try await probe(configuration)
                guard !Task.isCancelled else { return }
                self?.finish(.connected, generation: currentGeneration)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Connection failed."
                self?.finish(.failed(message), generation: currentGeneration)
            }
        }
    }

    func reset() {
        generation &+= 1
        task?.cancel()
        task = nil
        status = .idle
    }

    private func finish(_ result: Status, generation completedGeneration: Int) {
        guard generation == completedGeneration else { return }
        task = nil
        status = result
    }
}

/// Picker over the curated OpenRouter model catalog with a "Custom…" escape
/// hatch. The bound `slug` is always what the worker receives via `LLM_MODEL`.
@available(macOS 14.2, *)
private struct LLMModelPickerRow: View {
    @Binding var slug: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Model", selection: Binding(
                get: { LLMModelCatalog.option(for: slug) },
                set: { option in
                    if !option.isCustom {
                        slug = option.slug
                    } else if LLMModelCatalog.curated.contains(where: { $0.slug == slug && !$0.isCustom }) {
                        // Switching FROM a curated slug to Custom — clear so the
                        // user can type a new one without the old slug lingering.
                        slug = ""
                    }
                }
            )) {
                Section("Best for tone & nuance") {
                    ForEach(LLMModelCatalog.toneAware) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                Section("Fast & cheap") {
                    ForEach(LLMModelCatalog.fastAndCheap) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                Text(LLMModelCatalog.custom.displayName).tag(LLMModelCatalog.custom)
            }

            let selected = LLMModelCatalog.option(for: slug)
            if selected.isCustom {
                TextField("Slug (e.g. provider/model-id)", text: $slug)
                    .textFieldStyle(.roundedBorder)
                Text("Any OpenRouter model id. Browse openrouter.ai/models.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(selected.blurb)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
