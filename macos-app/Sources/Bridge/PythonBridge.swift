import Foundation
import OSLog

/// Launches the Python worker as a subprocess and communicates
/// via JSON over stdin/stdout/stderr.
///
/// - stdin: JSON `JobRequest`
/// - stdout: JSON `JobResult` (final output)
/// - stderr: newline-delimited JSON `ProgressUpdate` messages
@Observable
final class PythonBridge: @unchecked Sendable {

    var progress: Double = 0

    /// When true, invokes `python3 -m app.cli` from the python-worker
    /// directory instead of a frozen binary. Set via environment variable
    /// `CALLCAPTURE_DEV_MODE=1` or programmatically.
    var devMode: Bool

    /// Absolute path to the python-worker source directory, used in dev mode.
    var pythonWorkerDirectory: String

    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "PythonBridge"
    )

    private static let defaultTimeoutSeconds = 30 * 60
    private static let heartbeatIntervalSeconds: UInt64 = 30
    private static let maxRetries = 3
    /// Grace period after SIGTERM before escalating to SIGKILL.
    private static let terminationGraceSeconds: Double = 3

    /// The currently running worker subprocess, retained so it can be
    /// terminated on cancellation or app exit. Guarded by `processLock`.
    private var currentProcess: Process?
    private let processLock = NSLock()

    init() {
        let envWorkerDir = ProcessInfo.processInfo
            .environment["CALLCAPTURE_WORKER_DIR"]
        let workerDir = envWorkerDir ?? Self.defaultPythonWorkerDirectory()
        self.pythonWorkerDirectory = workerDir

        let envDevMode = ProcessInfo.processInfo
            .environment["CALLCAPTURE_DEV_MODE"] == "1"
        // Auto-enable dev mode if python-worker directory exists nearby
        let autoDetected = FileManager.default.fileExists(
            atPath: workerDir + "/app/cli.py"
        )
        self.devMode = envDevMode || autoDetected

        Self.logger.info(
            "PythonBridge init: devMode=\(self.devMode), workerDir=\(workerDir)"
        )
    }

    // MARK: - Public API

    /// Runs a transcription/processing job via the Python worker.
    ///
    /// - Parameters:
    ///   - request: The job request to send.
    ///   - env: Extra environment to pass to the worker process for this job
    ///     (e.g. `LLM_BASE_URL`/`LLM_MODEL`/`LLM_API_KEY`); defaults to none.
    /// - Returns: The job result from the worker.
    /// - Throws: `BridgeError` on failure.
    func runJob(request: JobRequest, env: [String: String] = [:]) async throws -> JobResult {
        var lastError: Error = BridgeError.maxRetriesExceeded(
            jobId: request.jobId,
            attempts: Self.maxRetries
        )

        for attempt in 1...Self.maxRetries {
            do {
                let result = try await executeWorker(request: request, env: env)
                return result
            } catch is CancellationError {
                // User/app cancelled — do not retry.
                Self.logger.info("Job \(request.jobId) cancelled")
                throw CancellationError()
            } catch {
                lastError = error
                Self.logger.warning(
                    "Job \(request.jobId) attempt \(attempt) failed: \(error)"
                )
                if attempt < Self.maxRetries {
                    let delay = UInt64(pow(2.0, Double(attempt)))
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        }

        throw lastError
    }

    /// Terminates the currently running worker subprocess, if any.
    ///
    /// Sends SIGTERM, then escalates to SIGKILL after a grace period if the
    /// process is still alive. Safe to call when no job is running.
    func cancelCurrentJob() {
        guard let process = takeCurrentProcess() else { return }
        terminateProcess(process)
    }

    // MARK: - Process Tracking

    private func setCurrentProcess(_ process: Process) {
        processLock.withLock { currentProcess = process }
    }

    private func clearCurrentProcess(_ process: Process) {
        processLock.withLock {
            if currentProcess === process { currentProcess = nil }
        }
    }

    private func takeCurrentProcess() -> Process? {
        processLock.withLock { currentProcess }
    }

    /// Sends SIGTERM to the worker, escalating to SIGKILL after a grace period.
    private func terminateProcess(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        Self.logger.info("Terminating worker process pid=\(pid) (SIGTERM)")
        process.terminate()

        DispatchQueue.global().asyncAfter(
            deadline: .now() + Self.terminationGraceSeconds
        ) {
            if process.isRunning {
                Self.logger.warning(
                    "Worker pid=\(pid) ignored SIGTERM; sending SIGKILL"
                )
                kill(pid, SIGKILL)
            }
        }
    }

    /// Checks if the Python worker binary is reachable and responds
    /// to `--version`.
    ///
    /// - Returns: The version string, or nil if the worker is unavailable.
    func healthCheck() async -> String? {
        let process = Process()

        if devMode {
            guard let python3 = Self.findPythonInterpreter(
                workerDir: pythonWorkerDirectory
            ) else {
                Self.logger.warning("python3 not found for dev mode health check")
                return nil
            }
            process.executableURL = URL(fileURLWithPath: python3)
            process.arguments = ["-m", "app.cli", "--version"]
            process.currentDirectoryURL = URL(
                fileURLWithPath: pythonWorkerDirectory
            )
        } else {
            guard let workerPath = Self.findWorkerBinary() else {
                return nil
            }
            process.executableURL = URL(fileURLWithPath: workerPath)
            process.arguments = ["--version"]
        }

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        } catch {
            Self.logger.debug("Worker health check failed: \(error)")
            return nil
        }
    }

    // MARK: - Private

    private func executeWorker(request: JobRequest, env: [String: String]) async throws -> JobResult {
        let process = Process()

        if devMode {
            guard let python3 = Self.findPythonInterpreter(
                workerDir: pythonWorkerDirectory
            ) else {
                throw BridgeError.workerNotFound(
                    searchedPaths: ["\(pythonWorkerDirectory)/.venv/bin/python", "python3 (via PATH)"]
                )
            }
            process.executableURL = URL(fileURLWithPath: python3)
            process.arguments = ["-m", "app.cli", request.command]
            process.currentDirectoryURL = URL(
                fileURLWithPath: pythonWorkerDirectory
            )
            Self.logger.info(
                "Dev mode: running python3 -m app.cli \(request.command) in \(self.pythonWorkerDirectory)"
            )
        } else {
            guard let workerPath = Self.findWorkerBinary() else {
                throw BridgeError.workerNotFound(
                    searchedPaths: Self.searchPaths()
                )
            }
            process.executableURL = URL(fileURLWithPath: workerPath)
            process.arguments = [request.command]
        }

        var processEnv = ProcessInfo.processInfo.environment
        for (key, value) in env where !value.isEmpty {
            processEnv[key] = value
        }
        process.environment = processEnv

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let encoder = JSONEncoder()
        guard let requestData = try? encoder.encode(request) else {
            throw BridgeError.stdinWriteFailed
        }

        // Track the process so it can be terminated on cancellation/app exit.
        setCurrentProcess(process)
        defer { clearCurrentProcess(process) }

        // If the surrounding Task is cancelled (user pressed Cancel, or the
        // app is quitting), kill the worker child instead of leaking it.
        return try await withTaskCancellationHandler {
            try await runProcess(
                process: process,
                request: request,
                requestData: requestData,
                stdinPipe: stdinPipe,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe
            )
        } onCancel: {
            self.terminateProcess(process)
        }
    }

    /// Runs the prepared worker process to completion, streaming progress and
    /// heartbeats, enforcing the job timeout.
    private func runProcess(
        process: Process,
        request: JobRequest,
        requestData: Data,
        stdinPipe: Pipe,
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) async throws -> JobResult {
        try process.run()

        // Write request to stdin, then close
        stdinPipe.fileHandleForWriting.write(requestData)
        stdinPipe.fileHandleForWriting.write(Data("\n".utf8))
        stdinPipe.fileHandleForWriting.closeFile()

        // Read stderr progress updates asynchronously
        let stderrHandle = stderrPipe.fileHandleForReading
        let progressTask = Task { [weak self] in
            await self?.readProgressUpdates(from: stderrHandle)
        }

        // Start heartbeat for long-running jobs
        let heartbeatTask = Task { [weak self] in
            await self?.sendHeartbeats(
                to: stdinPipe.fileHandleForWriting,
                process: process
            )
        }

        // Wait for process with timeout
        let result: JobResult = try await withThrowingTaskGroup(of: JobResult.self) { group in
            group.addTask {
                try await self.waitForResult(
                    process: process,
                    stdoutPipe: stdoutPipe,
                    stderrPipe: stderrPipe,
                    jobId: request.jobId
                )
            }

            group.addTask {
                try await Task.sleep(for: .seconds(Self.defaultTimeoutSeconds))
                process.terminate()
                throw BridgeError.workerTimedOut(
                    jobId: request.jobId,
                    timeoutSeconds: Self.defaultTimeoutSeconds
                )
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        heartbeatTask.cancel()
        progressTask.cancel()
        progress = 0

        return result
    }

    private func waitForResult(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        jobId: String
    ) async throws -> JobResult {
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { [weak self] terminatedProcess in
                let stdoutData = stdoutPipe.fileHandleForReading
                    .readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading
                    .readDataToEndOfFile()

                let exitCode = terminatedProcess.terminationStatus

                guard exitCode == 0 else {
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    Self.logger.error(
                        "Worker exited \(exitCode): \(stderr.prefix(500))"
                    )
                    // Surface the last meaningful stderr line (e.g. a Python
                    // exception) so the UI shows the real cause, not just a code.
                    let detail = stderr
                        .split(separator: "\n")
                        .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                        .map(String.init) ?? ""
                    let message = detail.isEmpty
                        ? "Worker exited with code \(exitCode)"
                        : "Worker exited with code \(exitCode): \(detail)"
                    continuation.resume(
                        returning: JobResult.error(jobId: jobId, message: message)
                    )
                    return
                }

                let decoder = JSONDecoder()
                guard let result = try? decoder.decode(
                    JobResult.self,
                    from: stdoutData
                ) else {
                    let raw = String(data: stdoutData, encoding: .utf8) ?? ""
                    Self.logger.error("Invalid response: \(raw.prefix(200))")
                    continuation.resume(
                        throwing: BridgeError.invalidResponse(rawOutput: raw)
                    )
                    return
                }

                continuation.resume(returning: result)
            }
        }
    }

    private func readProgressUpdates(from handle: FileHandle) async {
        let decoder = JSONDecoder()
        var buffer = Data()

        while !Task.isCancelled {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break }

            buffer.append(chunk)

            // Split on newlines and parse each line
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                if let update = try? decoder.decode(
                    ProgressUpdate.self,
                    from: Data(lineData)
                ) {
                    await MainActor.run {
                        self.progress = update.progress
                    }
                    Self.logger.debug(
                        "Progress: \(update.progress) stage=\(update.stage)"
                    )
                }
            }
        }
    }

    private func sendHeartbeats(
        to handle: FileHandle,
        process: Process
    ) async {
        let encoder = JSONEncoder()
        guard let pingData = try? encoder.encode(HeartbeatPing()) else {
            return
        }

        while !Task.isCancelled && process.isRunning {
            try? await Task.sleep(for: .seconds(Self.heartbeatIntervalSeconds))
            guard process.isRunning else { break }
            handle.write(pingData)
            handle.write(Data("\n".utf8))
        }
    }

    // MARK: - Worker Discovery

    private static func findWorkerBinary() -> String? {
        for path in searchPaths() {
            if FileManager.default.isExecutableFile(atPath: path) {
                logger.info("Found worker at \(path)")
                return path
            }
        }
        logger.warning("Worker binary not found in any search path")
        return nil
    }

    static func searchPaths() -> [String] {
        let bundle = Bundle.main.resourcePath ?? ""
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.path ?? ""

        return [
            "\(bundle)/worker/call-capture-worker",
            "\(appSupport)/CallCapture/worker/call-capture-worker",
            "./python-worker/dist/call-capture-worker/call-capture-worker"
        ]
    }

    /// Resolves the Python interpreter to run the worker with in dev mode.
    ///
    /// Prefers the project virtual environment (`<workerDir>/.venv/bin/python`)
    /// because the system `python3` (e.g. Xcode's Python 3.9) does not have the
    /// worker's dependencies (`click`, `pywhispercpp`, `pydantic`, ...)
    /// installed — running it produces `ModuleNotFoundError` and exit code 1.
    ///
    /// - Parameter workerDir: The python-worker source directory.
    /// - Returns: Path to a usable Python interpreter, or nil.
    private static func findPythonInterpreter(workerDir: String) -> String? {
        let venvCandidates = [
            "\(workerDir)/.venv/bin/python",
            "\(workerDir)/.venv/bin/python3",
        ]
        for path in venvCandidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                logger.info("Using venv interpreter: \(path)")
                return path
            }
        }
        logger.warning(
            "No .venv found in \(workerDir); falling back to system python3 (deps may be missing)"
        )
        return findPython3()
    }

    /// Locates `python3` on the system PATH.
    ///
    /// - Returns: Absolute path to `python3`, or nil if not found.
    private static func findPython3() -> String? {
        let candidates = [
            "/usr/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fall back to `which python3`
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty {
                return path
            }
        } catch {
            logger.debug("Failed to locate python3: \(error)")
        }

        return nil
    }

    /// Default python-worker directory relative to the macOS app location.
    private static func defaultPythonWorkerDirectory() -> String {
        let bundle = Bundle.main.bundlePath
        // When running from Xcode, the binary is inside .build/debug/
        // and python-worker is a sibling of macos-app.
        let buildDir = URL(fileURLWithPath: bundle)
        let maybeDev = buildDir
            .deletingLastPathComponent() // debug
            .deletingLastPathComponent() // .build
            .deletingLastPathComponent() // macos-app
            .appendingPathComponent("python-worker")

        if FileManager.default.fileExists(atPath: maybeDev.path) {
            return maybeDev.path
        }

        // Fall back to a relative path for development
        return "./python-worker"
    }
}
