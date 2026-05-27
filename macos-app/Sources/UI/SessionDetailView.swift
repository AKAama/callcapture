import SwiftUI
import OSLog

/// Full session detail view showing metadata, transcript previews,
/// and action buttons for transcription and export.
@available(macOS 14.2, *)
struct SessionDetailView: View {
    @Environment(AppModel.self) private var appModel
    let session: Session

    @State private var editableTitle: String = ""
    @State private var isTranscribing = false
    @State private var transcriptionError: String?
    @State private var saveMessage: String?
    /// Freshly-reloaded copy of the session, so transcript paths/status are
    /// current after transcription (the passed-in struct can be stale).
    @State private var liveSession: Session?
    /// Decoded conversation analysis sidecar for the insights panel.
    @State private var analysis: ConversationAnalysis?

    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "SessionDetail"
    )

    /// The most up-to-date session record available.
    private var current: Session { liveSession ?? session }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                metadataSection
                audioSection
                transcriptSection
                markdownSection
                insightsSection
                errorSection
                actionButtons
            }
            .padding()
        }
        .frame(minWidth: 380)
        .navigationTitle(session.title)
        .onAppear {
            editableTitle = session.title
            reload()
        }
    }

    private func reload() {
        liveSession = appModel.sessionManager.session(id: session.id)
        analysis = current.analysisPath.flatMap(ConversationAnalysis.load(fromPath:))
    }

    // MARK: - Sections

    @ViewBuilder
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: $editableTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .textFieldStyle(.plain)
                StatusBadge(status: session.status)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var metadataSection: some View {
        GroupBox("Details") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Type")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { RecordingType(rawValue: current.recordingType) ?? .callMeeting },
                        set: { newType in
                            // id is the stable original identity; `current` is read-only here.
                            appModel.sessionManager.updateRecordingType(
                                id: session.id,
                                recordingType: newType.rawValue
                            )
                            reload()
                        }
                    )) {
                        ForEach(RecordingType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                detailRow("Source App", session.sourceApp)
                detailRow("Started", session.startedAt.formatted(date: .abbreviated, time: .standard))
                if let endedAt = session.endedAt {
                    detailRow("Ended", endedAt.formatted(date: .abbreviated, time: .standard))
                }
                if let duration = session.durationSec {
                    detailRow("Duration", formattedDuration(duration))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var audioSection: some View {
        GroupBox("Audio") {
            HStack {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                Text(session.audioPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Open in Finder") {
                    NSWorkspace.shared.selectFile(
                        session.audioPath,
                        inFileViewerRootedAtPath: ""
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if let rawPath = current.transcriptRawPath,
           FileManager.default.fileExists(atPath: rawPath) {
            GroupBox("Raw Transcript") {
                TranscriptPreview(filePath: rawPath)
            }
        }
    }

    @ViewBuilder
    private var markdownSection: some View {
        if let mdPath = current.transcriptMarkdownPath,
           FileManager.default.fileExists(atPath: mdPath) {
            GroupBox("Markdown Note") {
                VStack(alignment: .leading, spacing: 8) {
                    TranscriptPreview(filePath: mdPath)
                    Button("Open Markdown") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: mdPath))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var insightsSection: some View {
        if let analysis, analysis.hasContent {
            GroupBox("Conversation Insights") {
                ConversationInsightsView(analysis: analysis)
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if current.status == "error", let error = transcriptionError {
            GroupBox("Error") {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if let saveMessage {
            Label(saveMessage, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        let hasMarkdown = current.transcriptMarkdownPath
            .map { FileManager.default.fileExists(atPath: $0) } ?? false

        HStack(spacing: 12) {
            if isTranscribing {
                ProgressView(value: appModel.pythonBridge.progress)
                    .progressViewStyle(.linear)
            }

            Spacer()

            if current.status == "completed" {
                transcribeButton(label: "Transcribe", engine: "local_whisper")
            }
            if current.status == "transcribed" {
                transcribeButton(label: "Re-process", engine: "local_whisper")
            }

            if hasMarkdown {
                Button("Save to Vault") { saveToConfiguredDirectory() }
                    .buttonStyle(.borderedProminent)
            }

            Menu("Export") {
                Button("Markdown (.md)") { exportFile(extension: "md") }
                Button("Plain Text (.txt)") { exportFile(extension: "txt") }
                Button("JSON (.json)") { exportFile(extension: "json") }
            }
            .menuStyle(.borderedButton)
            .controlSize(.regular)
            .disabled(!hasMarkdown)
        }
    }

    // MARK: - Actions

    private func transcribeButton(label: String, engine: String) -> some View {
        Button(label) {
            Task { await transcribe() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isTranscribing || appModel.state == .transcribing)
    }

    private func transcribe() async {
        isTranscribing = true
        transcriptionError = nil
        saveMessage = nil

        // Use `current` (DB-fresh) so Re-process picks up an edited recording type.
        await appModel.transcribeSession(current)

        if appModel.state == .error {
            transcriptionError = appModel.lastError
        }

        isTranscribing = false
        reload()
        Self.logger.info("Transcription flow completed for session \(session.id)")
    }

    private func exportFile(extension ext: String) {
        // The worker writes a markdown note and a JSON transcript; plain text
        // export reuses the markdown content.
        let sourcePath: String? = switch ext {
        case "json": current.transcriptRawPath
        default: current.transcriptMarkdownPath
        }
        guard let source = sourcePath,
              FileManager.default.fileExists(atPath: source) else {
            saveMessage = nil
            transcriptionError = "Nothing to export yet — transcribe first."
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(safeFileName(current.title)).\(ext)"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        try? FileManager.default.removeItem(at: url)
        do {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: source), to: url
            )
        } catch {
            transcriptionError = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Copies the markdown note into the configured Obsidian vault (or the
    /// output directory if no vault is set), creating the dated subfolder.
    private func saveToConfiguredDirectory() {
        transcriptionError = nil
        saveMessage = nil

        guard let mdPath = current.transcriptMarkdownPath,
              FileManager.default.fileExists(atPath: mdPath) else {
            transcriptionError = "No markdown note to save — transcribe first."
            return
        }

        let settings = appModel.settingsManager
        let vault = settings.obsidianExportDirectory
        let baseDir: String
        let subfolder: String
        if !vault.isEmpty {
            baseDir = vault
            subfolder = resolvedFolderPattern(
                settings.obsidianFolderPattern,
                date: current.startedAt
            )
        } else {
            baseDir = settings.outputDirectory
            subfolder = "exports"
        }

        let destDir = URL(fileURLWithPath: baseDir)
            .appendingPathComponent(subfolder, isDirectory: true)
        let destURL = destDir
            .appendingPathComponent("\(safeFileName(current.title)).md")

        do {
            try FileManager.default.createDirectory(
                at: destDir, withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: mdPath), to: destURL
            )
            saveMessage = "Saved to \(destURL.path)"
            Self.logger.info("Saved note to \(destURL.path)")
        } catch {
            transcriptionError = "Save failed: \(error.localizedDescription)"
            Self.logger.error("Save to vault failed: \(error)")
        }
    }

    /// Expands date tokens in an Obsidian folder pattern.
    private func resolvedFolderPattern(_ pattern: String, date: Date) -> String {
        let formatter = DateFormatter()
        let replacements: [(String, String)] = [
            ("{YYYY-MM}", "yyyy-MM"),
            ("{YYYY}", "yyyy"),
            ("{MM}", "MM"),
            ("{DD}", "dd")
        ]
        var result = pattern
        for (token, fmt) in replacements where result.contains(token) {
            formatter.dateFormat = fmt
            result = result.replacingOccurrences(
                of: token, with: formatter.string(from: date)
            )
        }
        return result
    }

    private func safeFileName(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
    }

    // MARK: - Helpers

    private func formattedDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
        }
    }
}

/// Reads the first portion of a file and displays it as a text preview.
@available(macOS 14.2, *)
private struct TranscriptPreview: View {
    let filePath: String
    private let maxPreviewLength = 1000

    var body: some View {
        if let content = previewContent {
            Text(content)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } else {
            Text("Unable to read file")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var previewContent: String? {
        guard let data = FileManager.default.contents(atPath: filePath),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        if text.count > maxPreviewLength {
            return String(text.prefix(maxPreviewLength)) + "..."
        }
        return text
    }
}
