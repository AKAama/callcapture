import SwiftUI
import OSLog

/// Application state representing the current recording lifecycle phase.
enum AppState: String, Sendable {
    case idle
    case recording
    case transcribing
    case error
}

/// Main application entry point. Renders as a menu bar extra with a popover.
@available(macOS 14.2, *)
@main
struct CallCaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel: AppModel

    init() {
        do {
            let database = try AppDatabase()
            _appModel = State(initialValue: AppModel(database: database))
        } catch {
            fatalError("Failed to open database: \(error)")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environment(appModel)
        } label: {
            Image(systemName: appModel.menuBarIconName)
        }
        .menuBarExtraStyle(.window)

        Window("Sessions", id: "sessions") {
            SessionListView()
                .environment(appModel)
        }

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView()
                .environment(appModel)
        }

        Window("Settings", id: "settings") {
            SettingsView()
                .environment(appModel)
        }
    }
}

/// Central application model holding shared state across the UI.
@available(macOS 14.2, *)
@Observable
final class AppModel {
    /// Process-wide reference used by `AppDelegate` to tear down audio and
    /// worker resources on quit/signal, where SwiftUI environment access is
    /// unavailable.
    @ObservationIgnored
    static weak var shared: AppModel?

    var state: AppState = .idle
    var lastError: String?
    var lastSessionTitle: String?
    var lastSessionDate: Date?
    var lastSessionDuration: Double?

    /// Available capture devices, refreshed from the system.
    var inputDevices: [AudioDeviceInfo] = []
    var outputDevices: [AudioDeviceInfo] = []
    /// Selected device UIDs. `nil` output = system default; `nil` mic = no mic.
    var selectedOutputUID: String?
    var selectedMicUID: String?
    var selectedRecordingType: RecordingType = .callMeeting

    let captureManager = AudioCaptureManager()
    let sessionManager: SessionManager
    let settingsManager: SettingsManager
    let pythonBridge = PythonBridge()
    let diarizationService = DiarizationService(provider: FluidAudioDiarizer())

    /// The in-flight auto-transcription task, retained so the user can cancel it.
    @ObservationIgnored
    private var transcriptionTask: Task<Void, Never>?

    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "AppModel"
    )

    /// Creates the app model backed by the given database.
    ///
    /// - Parameter database: The GRDB-backed application database.
    init(database: AppDatabase) {
        self.sessionManager = SessionManager(database: database)
        self.settingsManager = SettingsManager(database: database)
        AppModel.shared = self
        refreshAudioDevices()
    }

    /// Reloads the available input/output devices from the system and prunes
    /// any selection that no longer exists.
    func refreshAudioDevices() {
        inputDevices = AudioDeviceEnumerator.inputDevices()
        outputDevices = AudioDeviceEnumerator.outputDevices()

        if let mic = selectedMicUID,
           !inputDevices.contains(where: { $0.uid == mic }) {
            selectedMicUID = nil
        }
        if let out = selectedOutputUID,
           !outputDevices.contains(where: { $0.uid == out }) {
            selectedOutputUID = nil
        }
        Self.logger.info(
            "Audio devices: \(self.inputDevices.count) input, \(self.outputDevices.count) output"
        )
    }

    /// Synchronously releases audio capture and any running worker process.
    /// Called from `AppDelegate` on app termination and catchable signals.
    func teardownForExit() {
        transcriptionTask?.cancel()
        pythonBridge.cancelCurrentJob()
        captureManager.emergencyStop()
    }

    /// Cancels an in-progress transcription. The recorded audio is preserved
    /// and the session can be re-transcribed later from the session list.
    func cancelTranscription() {
        guard state == .transcribing else { return }
        Self.logger.info("Transcription cancelled by user")
        transcriptionTask?.cancel()
        pythonBridge.cancelCurrentJob()
        state = .idle
    }

    var menuBarIconName: String {
        switch state {
        case .idle: "waveform.circle"
        case .recording: "waveform.circle.fill"
        case .transcribing: "ellipsis.circle"
        case .error: "exclamationmark.circle"
        }
    }

    /// Toggles recording on/off. Creates a new session on start,
    /// finalizes capture on stop.
    func toggleRecording() async {
        switch state {
        case .idle, .error:
            state = .idle
            lastError = nil
            await startRecording()
        case .recording:
            await stopRecording()
        case .transcribing:
            break
        }
    }

    /// Transcribes the given session using the Python worker.
    ///
    /// Builds a `JobRequest` from the session and current settings,
    /// runs the worker, then updates the session record with result paths.
    /// Callable from `stopRecording` (auto-transcribe) and from
    /// `SessionDetailView` (manual transcribe button).
    ///
    /// - Parameter session: The session to transcribe.
    func transcribeSession(_ session: Session) async {
        state = .transcribing
        lastError = nil
        Self.logger.info("Transcription started for session \(session.id)")

        sessionManager.updateSessionStatus(
            id: session.id,
            status: "transcribing"
        )

        let request = JobRequest.transcribe(
            session: session,
            settings: settingsManager
        )

        let llmBaseURL: String
        let llmKey: String
        switch settingsManager.llmProvider {
        case .openrouter:
            llmBaseURL = "https://openrouter.ai/api/v1"
            llmKey = settingsManager.openRouterApiKey
        case .local:
            llmBaseURL = settingsManager.localLLMBaseURL
            llmKey = "ollama" // placeholder; local servers ignore it
        }
        var llmEnv = [
            "LLM_BASE_URL": llmBaseURL,
            "LLM_MODEL": settingsManager.llmModel,
            "LLM_API_KEY": llmKey,
        ]
        // Remote transcription providers read a provider-specific key from env.
        // For the `.auto` provider we resolve to AssemblyAI or Deepgram based
        // on the session's spoken language AND ship both keys so the worker
        // can use whichever it ends up routing through.
        if settingsManager.defaultEngine == .remote {
            switch settingsManager.remoteProvider {
            case .auto:
                if !settingsManager.assemblyAIApiKey.isEmpty {
                    llmEnv["ASSEMBLYAI_API_KEY"] = settingsManager.assemblyAIApiKey
                }
                if !settingsManager.deepgramApiKey.isEmpty {
                    llmEnv["DEEPGRAM_API_KEY"] = settingsManager.deepgramApiKey
                }
            case .assemblyai:
                if !settingsManager.assemblyAIApiKey.isEmpty {
                    llmEnv["ASSEMBLYAI_API_KEY"] = settingsManager.assemblyAIApiKey
                } else if !settingsManager.remoteApiKey.isEmpty {
                    // Back-compat for users who pasted into the old single field.
                    llmEnv["ASSEMBLYAI_API_KEY"] = settingsManager.remoteApiKey
                }
            case .deepgram:
                if !settingsManager.deepgramApiKey.isEmpty {
                    llmEnv["DEEPGRAM_API_KEY"] = settingsManager.deepgramApiKey
                } else if !settingsManager.remoteApiKey.isEmpty {
                    llmEnv["DEEPGRAM_API_KEY"] = settingsManager.remoteApiKey
                }
            case .groq:
                if !settingsManager.remoteApiKey.isEmpty {
                    llmEnv["GROQ_API_KEY"] = settingsManager.remoteApiKey
                }
            case .openai:
                if !settingsManager.remoteApiKey.isEmpty {
                    llmEnv["OPENAI_API_KEY"] = settingsManager.remoteApiKey
                }
            }
        }

        // Diarize the remote audio and write the turns sidecar the worker reads,
        // before transcription. No-ops unless the recording type diarizes and
        // models are downloaded; never blocks or fails transcription.
        await diarizationService.diarizeIfNeeded(
            session: session,
            modelsReady: settingsManager.diarizationModelsReady
        )

        do {
            let result = try await pythonBridge.runJob(request: request, env: llmEnv)

            if result.status == "error" || result.status == "failed" {
                let message = result.errorMessage
                    ?? result.warnings.first
                    ?? "Transcription failed"
                state = .error
                lastError = message
                sessionManager.updateSessionStatus(
                    id: session.id,
                    status: "error",
                    errorMessage: message
                )
                Self.logger.error(
                    "Transcription error for session \(session.id): \(message)"
                )
                return
            }

            sessionManager.updateSessionPaths(
                id: session.id,
                rawTranscriptPath: result.rawTranscriptPath,
                markdownPath: result.markdownPath,
                engineUsed: request.engine
            )
            sessionManager.updateAnalysisPath(
                id: session.id,
                analysisPath: result.analysisPath
            )
            sessionManager.updateSessionCost(
                id: session.id,
                costTranscription: result.costTranscription,
                costProcessing: result.costProcessing,
                costCurrency: result.costCurrency
            )
            sessionManager.updateSessionStatus(
                id: session.id,
                status: "transcribed"
            )

            state = .idle
            let duration = result.durationSec ?? 0
            Self.logger.info(
                "Transcription completed for session \(session.id), duration=\(duration)s"
            )
        } catch is CancellationError {
            // User cancelled — keep the recorded audio, mark as completed so
            // it can be re-transcribed later from the session list.
            state = .idle
            sessionManager.updateSessionStatus(
                id: session.id,
                status: "completed"
            )
            Self.logger.info(
                "Transcription cancelled for session \(session.id)"
            )
        } catch {
            let message = error.localizedDescription
            state = .error
            lastError = message
            sessionManager.updateSessionStatus(
                id: session.id,
                status: "error",
                errorMessage: message
            )
            Self.logger.error(
                "Transcription failed for session \(session.id): \(error)"
            )
        }
    }

    private func startRecording() async {
        do {
            let session = sessionManager.createSession(
                sourceApp: "System Audio",
                recordingType: selectedRecordingType
            )
            let outputURL = session.audioFileURL
            try await captureManager.startCapture(
                outputPath: outputURL,
                outputDeviceUID: selectedOutputUID,
                micDeviceUID: selectedMicUID
            )
            state = .recording
            Self.logger.info("Recording started for session \(session.id)")
        } catch {
            state = .error
            lastError = error.localizedDescription
            Self.logger.error("Failed to start recording: \(error)")
        }
    }

    private func stopRecording() async {
        do {
            try await captureManager.stopCapture()

            guard let session = sessionManager.currentSession else {
                state = .idle
                Self.logger.info("Recording stopped (no active session)")
                return
            }

            sessionManager.finalizeSession()

            // Reload the finalized record so we have the computed duration.
            let finalized = sessionManager.session(id: session.id) ?? session
            lastSessionTitle = finalized.title
            lastSessionDate = finalized.startedAt
            lastSessionDuration = finalized.durationSec

            Self.logger.info("Recording stopped for session \(session.id)")

            if settingsManager.autoProcessOnStop {
                Self.logger.info(
                    "Auto-transcription enabled, starting transcription"
                )
                // Run as a cancellable background task so Stop returns
                // immediately and the user can cancel transcription.
                state = .transcribing
                transcriptionTask = Task { [weak self] in
                    await self?.transcribeSession(finalized)
                }
            } else {
                state = .idle
            }
        } catch {
            state = .error
            lastError = error.localizedDescription
            Self.logger.error("Failed to stop recording: \(error)")
        }
    }
}
