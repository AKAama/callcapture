import CoreAudio
import Foundation
import OSLog

/// A selectable audio device (input or output).
struct AudioDeviceInfo: Identifiable, Hashable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
}

/// Enumerates the system's input (microphone) and output (speaker) devices
/// via the Core Audio HAL.
enum AudioDeviceEnumerator {

    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "AudioDevices"
    )

    /// Returns all devices that expose input channels (microphones, etc.).
    static func inputDevices() -> [AudioDeviceInfo] {
        devices(havingChannelsInScope: kAudioObjectPropertyScopeInput)
    }

    /// Returns all devices that expose output channels (speakers, etc.).
    static func outputDevices() -> [AudioDeviceInfo] {
        devices(havingChannelsInScope: kAudioObjectPropertyScopeOutput)
    }

    // MARK: - Private

    private static func devices(
        havingChannelsInScope scope: AudioObjectPropertyScope
    ) -> [AudioDeviceInfo] {
        allDeviceIDs().compactMap { id in
            guard channelCount(for: id, scope: scope) > 0 else { return nil }
            guard
                let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                let name = stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            // Skip our own private aggregate device.
            if name.hasPrefix("CallCapture-") { return nil }
            return AudioDeviceInfo(id: id, uid: uid, name: name)
        }
    }

    private static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
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
        guard sizeStatus == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &ids
        )
        guard status == noErr else { return [] }
        return ids
    }

    private static func channelCount(
        for deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID, &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return 0 }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &dataSize, bufferList
        ) == noErr else { return 0 }

        let ablPointer = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self)
        )
        return ablPointer.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        _ deviceID: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &ref
        )
        guard status == noErr, let value = ref?.takeRetainedValue() else {
            return nil
        }
        return value as String
    }
}
