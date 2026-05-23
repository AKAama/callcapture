import SwiftUI
import AVFoundation
import CoreAudio
import OSLog

/// Diagnostics view showing system information, permission states,
/// audio device availability, and Python worker health.
@available(macOS 14.2, *)
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var diagnostics = DiagnosticsInfo()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                systemSection
                permissionsSection
                audioDevicesSection
                workerSection
                coreAudioSection
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 500)
        .task { await diagnostics.refresh(bridge: appModel.pythonBridge) }
        .navigationTitle("Diagnostics")
    }

    @ViewBuilder
    private var systemSection: some View {
        DiagnosticsSection(title: "System") {
            DiagnosticRow(
                label: "macOS Version",
                value: diagnostics.macOSVersion
            )
            DiagnosticRow(
                label: "Chip",
                value: diagnostics.chipType
            )
        }
    }

    @ViewBuilder
    private var permissionsSection: some View {
        DiagnosticsSection(title: "Permissions") {
            DiagnosticRow(
                label: "Microphone",
                value: diagnostics.micPermission,
                isWarning: diagnostics.micPermission != "Granted"
            )
            DiagnosticRow(
                label: "Audio Capture",
                value: diagnostics.audioCapturePermission,
                isWarning: diagnostics.audioCapturePermission != "Available"
            )
        }
    }

    @ViewBuilder
    private var audioDevicesSection: some View {
        DiagnosticsSection(title: "Audio Devices") {
            ForEach(diagnostics.audioDevices, id: \.self) { device in
                DiagnosticRow(label: device, value: "")
            }
            if diagnostics.audioDevices.isEmpty {
                DiagnosticRow(label: "No devices found", value: "", isWarning: true)
            }
        }
    }

    @ViewBuilder
    private var workerSection: some View {
        DiagnosticsSection(title: "Python Worker") {
            DiagnosticRow(
                label: "Status",
                value: diagnostics.workerStatus,
                isWarning: diagnostics.workerStatus == "Not Found"
            )
            if let version = diagnostics.workerVersion {
                DiagnosticRow(label: "Version", value: version)
            }
        }
    }

    @ViewBuilder
    private var coreAudioSection: some View {
        DiagnosticsSection(title: "Core Audio Tap API") {
            DiagnosticRow(
                label: "Availability",
                value: diagnostics.tapAPIAvailable ? "Available" : "Not Available",
                isWarning: !diagnostics.tapAPIAvailable
            )
        }
    }
}

/// Groups diagnostic rows under a titled section.
private struct DiagnosticsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A single label-value row with optional warning highlighting.
private struct DiagnosticRow: View {
    let label: String
    let value: String
    var isWarning: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(isWarning ? .red : .primary)
        }
        .font(.subheadline)
    }
}

/// Collected diagnostic information, refreshed on demand.
@Observable
final class DiagnosticsInfo {

    var macOSVersion = ""
    var chipType = ""
    var micPermission = "Unknown"
    var audioCapturePermission = "Unknown"
    var audioDevices: [String] = []
    var workerStatus = "Checking..."
    var workerVersion: String?
    var tapAPIAvailable = false

    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "Diagnostics"
    )

    func refresh(bridge: PythonBridge) async {
        gatherSystemInfo()
        gatherPermissions()
        gatherAudioDevices()
        checkTapAPI()
        await checkWorker(bridge: bridge)
    }

    private func gatherSystemInfo() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        macOSVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        #if arch(arm64)
        chipType = "Apple Silicon"
        #else
        chipType = "Intel"
        #endif
    }

    private func gatherPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micPermission = "Granted"
        case .notDetermined: micPermission = "Not Requested"
        case .denied: micPermission = "Denied"
        case .restricted: micPermission = "Restricted"
        @unknown default: micPermission = "Unknown"
        }

        // Core Audio tap permission is granted at the system level.
        // We verify by checking if the API is callable.
        audioCapturePermission = tapAPIAvailable ? "Available" : "Check System Settings"
    }

    private func gatherAudioDevices() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0

        AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        )

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)

        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceIDs
        )

        audioDevices = deviceIDs.compactMap { deviceID in
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var nameRef: Unmanaged<CFString>?

            let status = withUnsafeMutablePointer(to: &nameRef) { ptr in
                AudioObjectGetPropertyData(
                    deviceID,
                    &nameAddress,
                    0,
                    nil,
                    &nameSize,
                    ptr
                )
            }
            guard status == noErr,
                  let cfName = nameRef?.takeUnretainedValue() else {
                return nil
            }
            return cfName as String
        }
    }

    private func checkTapAPI() {
        // CATapDescription is available on macOS 14.2+.
        // If we can reference it, the API is available.
        if #available(macOS 14.2, *) {
            tapAPIAvailable = true
        } else {
            tapAPIAvailable = false
        }
    }

    private func checkWorker(bridge: PythonBridge) async {
        if let version = await bridge.healthCheck() {
            workerStatus = "Healthy"
            workerVersion = version
        } else {
            workerStatus = "Not Found"
            workerVersion = nil
        }
    }
}
