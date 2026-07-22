import AppKit
import CoreAudio
import Foundation
import OSLog

/// A Core Audio client process that can be selected for application audio capture.
struct AudioProcessInfo: Identifiable, Hashable, Sendable {
    let id: AudioObjectID
    let pid: pid_t
    let name: String
    let bundleID: String?
}

/// Enumerates processes currently connected to the Core Audio HAL.
enum AudioProcessEnumerator {
    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "AudioProcessEnumerator"
    )

    /// Returns selectable audio processes, excluding CallCapture itself.
    static func processes() -> [AudioProcessInfo] {
        let candidates = processObjectIDs().compactMap { objectID -> AudioProcessInfo? in
            guard let processID = processID(for: objectID) else { return nil }

            let application = NSRunningApplication(processIdentifier: processID)
            let bundleID = application?.bundleIdentifier
            let name = application?.localizedName
                ?? bundleID
                ?? "Process \(processID)"

            return AudioProcessInfo(
                id: objectID,
                pid: processID,
                name: name,
                bundleID: bundleID
            )
        }

        return normalize(candidates, currentPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// Removes unusable and duplicate process records and sorts them for display.
    static func normalize(
        _ candidates: [AudioProcessInfo],
        currentPID: pid_t
    ) -> [AudioProcessInfo] {
        var seenPIDs = Set<pid_t>()
        return candidates
            .filter { process in
                guard process.pid > 0, process.pid != currentPID else { return false }
                return seenPIDs.insert(process.pid).inserted
            }
            .sorted { lhs, rhs in
                let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if comparison == .orderedSame {
                    return lhs.pid < rhs.pid
                }
                return comparison == .orderedAscending
            }
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else {
            if sizeStatus != noErr {
                logger.error("Could not read audio process list size: \(sizeStatus)")
            }
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &objectIDs
        )
        guard dataStatus == noErr else {
            logger.error("Could not read audio process list: \(dataStatus)")
            return []
        }
        return objectIDs
    }

    private static func processID(for objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processID: pid_t = 0
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &processID
        )
        guard status == noErr else {
            logger.error("Could not read PID for audio process \(objectID): \(status)")
            return nil
        }
        return processID
    }
}
