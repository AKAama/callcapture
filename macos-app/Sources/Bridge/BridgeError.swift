import Foundation

/// Errors that can occur when communicating with the Python worker.
enum BridgeError: LocalizedError {
    case workerNotFound(searchedPaths: [String])
    case workerCrashed(exitCode: Int32, stderr: String)
    case workerTimedOut(jobId: String, timeoutSeconds: Int)
    case heartbeatFailed(jobId: String)
    case invalidResponse(rawOutput: String)
    case stdinWriteFailed
    case maxRetriesExceeded(jobId: String, attempts: Int)

    var errorDescription: String? {
        switch self {
        case .workerNotFound(let paths):
            "Python worker binary not found. Searched: \(paths.joined(separator: ", "))"
        case .workerCrashed(let code, let stderr):
            "Python worker exited with code \(code). \(stderr.prefix(500))"
        case .workerTimedOut(let jobId, let timeout):
            "Job \(jobId) timed out after \(timeout) seconds."
        case .heartbeatFailed(let jobId):
            "Heartbeat failed for job \(jobId). Worker may be unresponsive."
        case .invalidResponse(let raw):
            "Invalid JSON response from worker: \(raw.prefix(200))"
        case .stdinWriteFailed:
            "Failed to write request to worker stdin."
        case .maxRetriesExceeded(let jobId, let attempts):
            "Job \(jobId) failed after \(attempts) attempts."
        }
    }
}
