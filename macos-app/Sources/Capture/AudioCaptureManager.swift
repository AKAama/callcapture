import AVFoundation
import CoreAudio
import OSLog

/// Manages Core Audio process taps to capture system audio output.
///
/// Uses `CATapDescription` and `AudioHardwareCreateProcessTap`
/// (macOS 14.2+) to intercept the default system output and write
/// 16 kHz mono PCM WAV files suitable for ASR processing.
///
/// The capture pipeline:
/// 1. Create a process tap via `AudioHardwareCreateProcessTap`
/// 2. Create an aggregate device that includes the tap
/// 3. Set the aggregate device as `AVAudioEngine` input
/// 4. Install a tap on the input node, convert to 16 kHz mono, write WAV
@available(macOS 14.2, *)
@Observable
final class AudioCaptureManager {

    private(set) var isRecording = false

    private var tapID: AudioObjectID = .init(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = .init(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var fileWriter: AudioFileWriter?

    /// Mono float32 format at the aggregate's input sample rate. All IO buffers
    /// (tap channels + any mic channels) are downmixed into this before
    /// conversion to the target ASR format.
    private var mixFormat: AVAudioFormat?
    /// Target ASR format (16 kHz mono) the mix is converted to.
    private var targetFormat: AVAudioFormat?
    /// Converts mix-format buffers to the target format.
    private var converter: AVAudioConverter?
    /// Separate-stem writers, created only when a mic is selected.
    private var micWriter: AudioFileWriter?
    private var systemWriter: AudioFileWriter?
    private var micConverter: AVAudioConverter?
    private var systemConverter: AVAudioConverter?
    /// Channel count of the system tap, used to split the IO buffer list.
    private var systemTapChannels: Int = 0
    /// Counts buffers delivered by the IO proc, for first-buffer diagnostics.
    private var bufferCount = 0

    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "AudioCapture"
    )

    private static let targetSampleRate: Double = 16_000
    private static let targetChannelCount: AVAudioChannelCount = 1

    // MARK: - Public API

    /// Starts capturing system audio output (and optionally a microphone,
    /// mixed in) to a WAV file.
    ///
    /// - Parameters:
    ///   - outputPath: Destination URL for the recorded WAV file.
    ///   - outputDeviceUID: UID of the output device to tap. `nil` taps the
    ///     system default output.
    ///   - micDeviceUID: UID of a microphone to mix into the recording, or
    ///     `nil` to capture system output only.
    /// - Throws: `CaptureError` if tap or device creation fails.
    func startCapture(
        outputPath: URL,
        outputDeviceUID: String? = nil,
        micDeviceUID: String? = nil
    ) async throws {
        guard !isRecording else { throw CaptureError.alreadyRecording }

        Self.logger.info(
            "startCapture: output=\(outputDeviceUID ?? "default"), mic=\(micDeviceUID ?? "none")"
        )

        // Create a stereo global mixdown tap of all processes (system audio).
        // Empty exclude-list captures everything. `deviceUID` restricts the
        // tap to a specific output device (nil = system default).
        let tapUUID = UUID()
        let tapDescription = CATapDescription(
            stereoGlobalTapButExcludeProcesses: []
        )
        tapDescription.name = "CallCapture-SystemTap"
        tapDescription.uuid = tapUUID
        if let outputDeviceUID {
            tapDescription.deviceUID = outputDeviceUID
        }

        var tapObjectID = AudioObjectID(kAudioObjectUnknown)

        Self.logger.info("startCapture: creating process tap")
        let tapStatus = AudioHardwareCreateProcessTap(
            tapDescription,
            &tapObjectID
        )
        guard tapStatus == noErr else {
            Self.logger.error("Tap creation failed with OSStatus: \(tapStatus)")
            throw CaptureError.tapCreationFailed(status: tapStatus)
        }

        self.tapID = tapObjectID
        Self.logger.info("startCapture: tap created, tapID=\(tapObjectID)")

        // Build a private aggregate device that hosts the tap, plus the mic
        // sub-device when one is selected (so its channels are mixed in).
        let aggregateDevice = try Self.createAggregateDevice(
            tapUUID: tapUUID,
            micDeviceUID: micDeviceUID
        )
        self.aggregateDeviceID = aggregateDevice
        Self.logger.info("startCapture: aggregate device created, ID=\(aggregateDevice)")

        // Read the aggregate's combined input format only for its sample rate.
        // The IO proc may deliver several separate buffers (tap stream + mic
        // stream); we downmix all of them into a single mono stream at this
        // rate, then convert to 16 kHz.
        let inputFormat = try Self.deviceInputFormat(deviceID: aggregateDevice)
        Self.logger.info(
            "startCapture: aggregate input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch"
        )

        guard let mixFormat = AVAudioFormat(
            standardFormatWithSampleRate: inputFormat.sampleRate,
            channels: 1
        ) else {
            Self.logger.error("startCapture: failed to create mix format")
            destroyAggregateDevice()
            destroyTap()
            throw CaptureError.tapCreationFailed(status: -1)
        }

        guard let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: Self.targetSampleRate,
            channels: Self.targetChannelCount
        ) else {
            Self.logger.error("startCapture: failed to create output format")
            destroyAggregateDevice()
            destroyTap()
            throw CaptureError.tapCreationFailed(status: -2)
        }

        guard let converter = AVAudioConverter(
            from: mixFormat,
            to: outputFormat
        ) else {
            Self.logger.error("startCapture: failed to create converter")
            destroyAggregateDevice()
            destroyTap()
            throw CaptureError.tapCreationFailed(status: -3)
        }

        Self.logger.info("startCapture: creating file writer at \(outputPath.path)")
        let writer = try AudioFileWriter(
            outputPath: outputPath,
            format: outputFormat
        )

        self.mixFormat = mixFormat
        self.targetFormat = outputFormat
        self.converter = converter
        self.fileWriter = writer
        self.bufferCount = 0

        // Record the tap channel count so the IO proc can split mic vs system.
        self.systemTapChannels = Self.tapChannelCount(tapID: self.tapID)

        // When a mic is mixed in, also write separate mic/system stems for
        // later diarization. Named alongside the mixed file.
        if micDeviceUID != nil {
            let dir = outputPath.deletingLastPathComponent()
            let stem = outputPath.deletingPathExtension().lastPathComponent  // "<id>"
            let micURL = dir.appendingPathComponent("\(stem)_mic.wav")
            let systemURL = dir.appendingPathComponent("\(stem)_system.wav")
            // Both filenames end in `.wav` so AVAudioFile writes RIFF/WAV (a
            // non-`.wav` extension would silently produce CAF).
            self.micWriter = try AudioFileWriter(outputPath: micURL, format: outputFormat)
            self.systemWriter = try AudioFileWriter(outputPath: systemURL, format: outputFormat)
            self.micConverter = AVAudioConverter(from: mixFormat, to: outputFormat)
            self.systemConverter = AVAudioConverter(from: mixFormat, to: outputFormat)
            Self.logger.info("startCapture: writing mic+system stems (tapCh=\(self.systemTapChannels))")
        }

        // Install an IO proc on the aggregate device. Unlike
        // AVAudioEngine.installTap (which does not reliably pull audio from a
        // process-tap aggregate device), an IO proc receives the tapped audio
        // directly on a real-time thread. `self` is passed via the client-data
        // pointer because the C callback cannot capture context.
        Self.logger.info("startCapture: creating IO proc on aggregate device")
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(
            aggregateDevice,
            { _, _, inInputData, _, _, _, inClientData -> OSStatus in
                guard let inClientData else { return noErr }
                let manager = Unmanaged<AudioCaptureManager>
                    .fromOpaque(inClientData)
                    .takeUnretainedValue()
                return manager.handleIO(inInputData)
            },
            selfPtr,
            &procID
        )
        guard createStatus == noErr, let procID else {
            Self.logger.error("startCapture: AudioDeviceCreateIOProcID failed: \(createStatus)")
            self.converter = nil
            self.fileWriter = nil
            try? self.micWriter?.finalize()
            try? self.systemWriter?.finalize()
            self.micWriter = nil
            self.systemWriter = nil
            self.micConverter = nil
            self.systemConverter = nil
            destroyAggregateDevice()
            destroyTap()
            throw CaptureError.tapCreationFailed(status: createStatus)
        }
        self.ioProcID = procID

        Self.logger.info("startCapture: starting aggregate device IO")
        let startStatus = AudioDeviceStart(aggregateDevice, procID)
        guard startStatus == noErr else {
            Self.logger.error("startCapture: AudioDeviceStart failed: \(startStatus)")
            AudioDeviceDestroyIOProcID(aggregateDevice, procID)
            self.ioProcID = nil
            self.converter = nil
            self.fileWriter = nil
            try? self.micWriter?.finalize()
            try? self.systemWriter?.finalize()
            self.micWriter = nil
            self.systemWriter = nil
            self.micConverter = nil
            self.systemConverter = nil
            destroyAggregateDevice()
            destroyTap()
            throw CaptureError.tapCreationFailed(status: startStatus)
        }

        self.isRecording = true
        Self.logger.info("Capture started, writing to \(outputPath.path)")
    }

    /// Stops the current recording and finalizes the WAV file.
    ///
    /// - Throws: `CaptureError.notRecording` if no recording is active,
    ///   or `CaptureError.finalizationFailed` if the file cannot be closed.
    func stopCapture() async throws {
        guard isRecording else { throw CaptureError.notRecording }

        stopIOProc()

        try? micWriter?.finalize()
        try? systemWriter?.finalize()

        do {
            try fileWriter?.finalize()
        } catch {
            Self.logger.error("File finalization failed: \(error)")
            fileWriter = nil
            converter = nil
            micWriter = nil
            systemWriter = nil
            micConverter = nil
            systemConverter = nil
            destroyAggregateDevice()
            destroyTap()
            isRecording = false
            throw CaptureError.finalizationFailed(underlying: error)
        }

        fileWriter = nil
        converter = nil
        micWriter = nil
        systemWriter = nil
        micConverter = nil
        systemConverter = nil
        destroyAggregateDevice()
        destroyTap()
        isRecording = false

        Self.logger.info("Capture stopped and file finalized")
    }

    /// Synchronously releases all capture resources without throwing.
    ///
    /// Used on app termination and catchable signals, where awaiting is not
    /// possible. Best-effort: finalizes the WAV file if open, then tears down
    /// the audio engine, aggregate device, and process tap. Safe to call when
    /// not recording.
    func emergencyStop() {
        guard isRecording else { return }
        Self.logger.warning("emergencyStop: releasing capture resources")

        stopIOProc()

        try? fileWriter?.finalize()
        try? micWriter?.finalize()
        try? systemWriter?.finalize()
        fileWriter = nil
        converter = nil
        micWriter = nil
        systemWriter = nil
        micConverter = nil
        systemConverter = nil

        destroyAggregateDevice()
        destroyTap()
        isRecording = false
    }

    // MARK: - Private Helpers

    /// Stops and destroys the aggregate device IO proc, if active.
    private func stopIOProc() {
        guard let procID = ioProcID else { return }
        AudioDeviceStop(aggregateDeviceID, procID)
        AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        ioProcID = nil
    }

    /// Index into a buffer list at which the system (tap) buffers begin.
    ///
    /// The aggregate device lists mic sub-device buffers first, then tap
    /// buffers. The trailing buffers whose channels sum to `systemChannels`
    /// are the system stem; everything before them is the mic stem.
    ///
    /// - Returns: The split index (system buffers are `index..<count`). Returns
    ///   `0` (treat everything as system) if no clean split sums to
    ///   `systemChannels`, which is the safe default for the no-mic case.
    static func systemBufferSplit(channelCounts: [Int], systemChannels: Int) -> Int {
        var trailing = 0
        var index = channelCounts.count
        while index > 0 {
            trailing += channelCounts[index - 1]
            index -= 1
            if trailing == systemChannels { return index }
            if trailing > systemChannels { break }
        }
        return 0
    }

    /// Sums the given buffer-index range of an aggregate buffer list into a
    /// freshly allocated mono buffer (channel-averaged per stream, then averaged
    /// across streams). Returns nil if the range is empty or invalid.
    private func downmix(
        _ abl: UnsafeMutableAudioBufferListPointer,
        indices: Range<Int>,
        frameCount: Int,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard !indices.isEmpty, frameCount > 0 else { return nil }
        guard let out = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = AVAudioFrameCount(frameCount)
        for i in 0..<frameCount { dst[i] = 0 }

        var streams = 0
        for bufferIndex in indices {
            let buffer = abl[bufferIndex]
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let raw = buffer.mData else { continue }
            let src = raw.assumingMemoryBound(to: Float.self)
            let bufFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let n = min(bufFrames, frameCount)
            for f in 0..<n {
                var sum: Float = 0
                for c in 0..<channels { sum += src[f * channels + c] }
                dst[f] += sum / Float(channels)
            }
            streams += 1
        }
        if streams > 1 {
            let scale = 1.0 / Float(streams)
            for i in 0..<frameCount { dst[i] *= scale }
        }
        return out
    }

    /// Handles one IO callback. The aggregate may deliver several separate
    /// float32 buffers (e.g. the system-audio tap and a mic stream). All of
    /// them are summed/averaged into a single mono buffer (the mix), then
    /// converted to the 16 kHz target format and written. Runs on a real-time
    /// audio thread.
    private func handleIO(_ inInputData: UnsafePointer<AudioBufferList>) -> OSStatus {
        guard
            let mixFormat,
            let targetFormat,
            let converter,
            let writer = fileWriter
        else { return noErr }

        let abl = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inInputData)
        )
        guard abl.count > 0 else { return noErr }

        let first = abl[0]
        let firstChannels = Int(first.mNumberChannels)
        guard firstChannels > 0, first.mDataByteSize > 0 else { return noErr }
        let frameCount = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * firstChannels)
        guard frameCount > 0 else { return noErr }

        bufferCount += 1
        if bufferCount == 1 {
            let shapes = abl.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }
                .joined(separator: ", ")
            Self.logger.info("IO buffers: count=\(abl.count) [\(shapes)] frames=\(frameCount) tapCh=\(self.systemTapChannels)")
        }

        // Full mix (all buffers) -> main writer (unchanged behavior).
        if let mix = downmix(abl, indices: 0..<abl.count, frameCount: frameCount, format: mixFormat) {
            handleAudioBuffer(mix, converter: converter, outputFormat: targetFormat, writer: writer)
        }

        // Separate stems (only when mic writers were created).
        if let micWriter, let systemWriter,
           let micConverter, let systemConverter {
            let channelCounts = abl.map { Int($0.mNumberChannels) }
            let split = Self.systemBufferSplit(
                channelCounts: channelCounts, systemChannels: systemTapChannels
            )
            if split == 0 && bufferCount == 1 {
                Self.logger.warning("Mic selected but buffer split found no mic buffers (tapCh=\(self.systemTapChannels)); mic stem will be empty")
            }
            if split > 0, let micBuf = downmix(abl, indices: 0..<split, frameCount: frameCount, format: mixFormat) {
                handleAudioBuffer(micBuf, converter: micConverter, outputFormat: targetFormat, writer: micWriter)
            }
            if let sysBuf = downmix(abl, indices: split..<abl.count, frameCount: frameCount, format: mixFormat) {
                handleAudioBuffer(sysBuf, converter: systemConverter, outputFormat: targetFormat, writer: systemWriter)
            }
        }
        return noErr
    }

    private func handleAudioBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        writer: AudioFileWriter
    ) {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * ratio
        )
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: frameCapacity
        ) else { return }

        var error: NSError?
        var inputConsumed = false
        converter.convert(
            to: convertedBuffer,
            error: &error
        ) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            Self.logger.error("Conversion error: \(error)")
            return
        }

        writer.writeBuffer(convertedBuffer)
    }

    private func destroyTap() {
        if tapID != kAudioObjectUnknown {
            let err = AudioHardwareDestroyProcessTap(tapID)
            if err != noErr {
                Self.logger.warning("Failed to destroy process tap: OSStatus=\(err)")
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func destroyAggregateDevice() {
        if aggregateDeviceID != kAudioObjectUnknown {
            let err = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if err != noErr {
                Self.logger.warning("Failed to destroy aggregate device: OSStatus=\(err)")
            }
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Device Utilities

    /// Reads the channel count of a process tap's stream format.
    private static func tapChannelCount(tapID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mChannelsPerFrame > 0 else { return 2 }
        return Int(asbd.mChannelsPerFrame)
    }

    /// Reads the combined input stream format of an audio device.
    ///
    /// For our aggregate device this reflects the tap channels plus any mic
    /// sub-device channels. Polled briefly because an aggregate device may not
    /// report its format immediately after creation.
    ///
    /// - Parameter deviceID: The `AudioObjectID` of the device.
    /// - Returns: An `AVAudioFormat` describing the device's input.
    /// - Throws: `CaptureError` if the format cannot be read or is invalid.
    private static func deviceInputFormat(
        deviceID: AudioObjectID
    ) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        var status: OSStatus = noErr
        for attempt in 1...5 {
            status = AudioObjectGetPropertyData(
                deviceID, &address, 0, nil, &size, &asbd
            )
            if status == noErr, asbd.mSampleRate > 0 { break }
            if attempt < 5 { Thread.sleep(forTimeInterval: 0.05) }
        }
        guard status == noErr, asbd.mSampleRate > 0 else {
            logger.error("Failed to read device input format: OSStatus=\(status)")
            throw CaptureError.tapCreationFailed(status: status)
        }
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            logger.error("Device input ASBD could not be converted to AVAudioFormat")
            throw CaptureError.tapCreationFailed(status: -10)
        }
        return format
    }

    // MARK: - Aggregate Device

    /// Creates a private aggregate device that hosts the process tap, and
    /// optionally a microphone sub-device whose channels are mixed in.
    ///
    /// With no mic, the sub-device list is empty and only the tap is present
    /// (including a physical *output* device here makes the IO proc read its
    /// silent input streams instead of the tap). When a mic is selected, it is
    /// added as a sub-device with drift compensation so its channels appear in
    /// the aggregate's combined input alongside the tap.
    ///
    /// - Parameters:
    ///   - tapUUID: The UUID assigned to the `CATapDescription`.
    ///   - micDeviceUID: Optional microphone device UID to add as a sub-device.
    /// - Returns: The `AudioObjectID` of the new aggregate device.
    /// - Throws: `CaptureError` if aggregate device creation fails.
    private static func createAggregateDevice(
        tapUUID: UUID,
        micDeviceUID: String?
    ) throws -> AudioObjectID {
        let aggregateUID = UUID().uuidString

        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CallCapture-Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        if let micDeviceUID {
            // The mic is a real device, so it must be the clock master that
            // drives the aggregate; the tap follows it with drift compensation.
            // Without a master sub-device the aggregate will not run IO.
            description[kAudioAggregateDeviceSubDeviceListKey] = [[
                kAudioSubDeviceUIDKey: micDeviceUID,
                kAudioSubDeviceDriftCompensationKey: 1
            ]]
            description[kAudioAggregateDeviceMainSubDeviceKey] = micDeviceUID
        } else {
            // Tap-only: the tap auto-starts and drives the aggregate itself.
            description[kAudioAggregateDeviceSubDeviceListKey] = [] as [[String: Any]]
        }

        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(
            description as CFDictionary,
            &aggregateDeviceID
        )

        guard status == noErr else {
            logger.error(
                "Aggregate device creation failed: OSStatus=\(status)"
            )
            throw CaptureError.tapCreationFailed(status: status)
        }

        logger.info("Aggregate device created: ID=\(aggregateDeviceID), UID=\(aggregateUID)")
        return aggregateDeviceID
    }
}
