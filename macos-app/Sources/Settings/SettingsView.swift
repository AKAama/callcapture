import SwiftUI

/// Settings view for configuring transcription, post-processing,
/// speaker options, and export paths.
@available(macOS 14.2, *)
struct SettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.settingsManager
        Form {
            transcriptionSection(settings: settings)
            apiKeysSection(settings: settings)
            postProcessingSection(settings: settings)
            speakerSection(settings: settings)
            exportSection(settings: settings)
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 520)
        .navigationTitle("Settings")
    }

    // MARK: - Sections

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

    @ViewBuilder
    private func apiKeysSection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings
        Section("API Keys") {
            if settings.llmProvider == .openrouter {
                SecureField("OpenRouter API Key", text: $settings.openRouterApiKey)
            }

            if settings.defaultEngine == .remote {
                SecureField(
                    "\(settings.remoteProvider.displayName) API Key",
                    text: $settings.remoteApiKey
                )
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

            TextField("Model", text: $settings.llmModel)
                .textFieldStyle(.roundedBorder)

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
    private func speakerSection(settings: SettingsManager) -> some View {
        @Bindable var settings = settings
        Section("Speaker Options") {
            HStack {
                Toggle("Speaker diarization", isOn: .constant(false))
                    .disabled(true)
                Text("Coming in v1.1")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
