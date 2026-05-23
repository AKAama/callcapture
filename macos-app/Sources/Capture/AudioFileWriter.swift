import AVFoundation
import OSLog

/// Writes PCM audio buffers to a WAV file with proper header management.
///
/// Uses atomic write semantics: audio is written to a temporary file,
/// then renamed to the final path on `finalize()`. This prevents
/// corrupt output if the process crashes mid-write.
final class AudioFileWriter {

    private let finalPath: URL
    private let tempPath: URL
    private var audioFile: AVAudioFile?
    private var totalFramesWritten: AVAudioFrameCount = 0

    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "AudioFileWriter"
    )

    /// Creates a new audio file writer.
    ///
    /// - Parameters:
    ///   - outputPath: Final destination for the WAV file.
    ///   - format: Audio format describing sample rate and channel layout.
    /// - Throws: If the temporary file cannot be created.
    init(outputPath: URL, format: AVAudioFormat) throws {
        self.finalPath = outputPath
        // The temp file MUST keep a `.wav` extension: `AVAudioFile` infers the
        // container format from the path extension. A `.tmp` extension makes it
        // silently write CAF instead of RIFF/WAV, which downstream WAV readers
        // (whisper) reject with "file does not start with RIFF id".
        self.tempPath = outputPath
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial.wav")

        let directory = outputPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        self.audioFile = try AVAudioFile(
            forWriting: tempPath,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        Self.logger.info("Writer initialized: temp=\(self.tempPath.lastPathComponent)")
    }

    /// Appends a PCM buffer to the file.
    ///
    /// - Parameter buffer: Audio data to write. Must match the format
    ///   specified during initialization.
    func writeBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }

        do {
            try audioFile?.write(from: buffer)
            totalFramesWritten += buffer.frameLength
        } catch {
            Self.logger.error("Write failed at frame \(self.totalFramesWritten): \(error)")
        }
    }

    /// Finalizes the WAV file by closing the audio file handle and
    /// atomically moving the temp file to the final destination.
    ///
    /// - Throws: If the file rename operation fails.
    func finalize() throws {
        audioFile = nil

        let manager = FileManager.default

        // Remove any existing file at the final path
        if manager.fileExists(atPath: finalPath.path) {
            try manager.removeItem(at: finalPath)
        }

        try manager.moveItem(at: tempPath, to: finalPath)

        Self.logger.info("Finalized: \(self.totalFramesWritten) frames written to \(self.finalPath.lastPathComponent)")
    }

    deinit {
        // Clean up temp file if finalize was never called
        if audioFile != nil {
            audioFile = nil
            try? FileManager.default.removeItem(at: tempPath)
        }
    }
}
