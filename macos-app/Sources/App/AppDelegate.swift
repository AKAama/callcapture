import AppKit
import OSLog

/// Application delegate handling process-level lifecycle concerns that
/// SwiftUI's `App` protocol does not cover:
///
/// - **Single-instance enforcement** — a menu bar (`LSUIElement`) app gives
///   no visual cue that a copy is already running, so launching from Xcode
///   while a double-clicked copy is live produces duplicate menu bar icons.
///   The newer instance detects the older one and terminates itself.
/// - **Graceful teardown** — on normal quit (Cmd-Q) and on catchable signals
///   (SIGTERM/SIGINT) the audio capture and any running Python worker child
///   process are torn down so they do not leak.
@available(macOS 14.2, *)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var signalSources: [DispatchSourceSignal] = []

    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "AppDelegate"
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateIfDuplicateInstance() { return }
        installSignalHandlers()
        Self.logger.info("AppDelegate launched (single instance confirmed)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.logger.info("applicationWillTerminate: tearing down")
        AppModel.shared?.teardownForExit()
    }

    // MARK: - Single Instance

    /// Terminates this process if another instance with the same bundle
    /// identifier launched earlier.
    ///
    /// Comparing launch dates ensures exactly one instance survives when two
    /// are started near-simultaneously: each keeps the older, quits the newer.
    ///
    /// - Returns: `true` if this instance is terminating itself.
    @discardableResult
    private func terminateIfDuplicateInstance() -> Bool {
        let me = NSRunningApplication.current
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == me.bundleIdentifier
                && $0.processIdentifier != me.processIdentifier
        }
        guard !others.isEmpty else { return false }

        let myLaunch = me.launchDate ?? Date.distantFuture
        let olderInstance = others.first { other in
            let theirLaunch = other.launchDate ?? Date.distantPast
            return theirLaunch < myLaunch
        }

        guard let existing = olderInstance else { return false }

        Self.logger.warning(
            "Another instance (pid \(existing.processIdentifier)) is already running; terminating self"
        )
        existing.activate()
        NSApp.terminate(nil)
        return true
    }

    // MARK: - Signal Handling

    /// Installs handlers for catchable termination signals so the app can
    /// release audio resources before exiting. SIGKILL cannot be caught;
    /// private Core Audio aggregate devices are reclaimed by `coreaudiod`
    /// when the process dies in that case.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            // Ignore default disposition so the dispatch source receives it.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: sig,
                queue: .main
            )
            source.setEventHandler {
                Task { @MainActor in
                    Self.logger.warning("Caught signal \(sig); tearing down and exiting")
                    AppModel.shared?.teardownForExit()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
