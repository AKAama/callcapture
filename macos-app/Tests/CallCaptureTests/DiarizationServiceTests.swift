import Testing
import Foundation
@testable import CallCapture

/// Test double that records calls and returns/throws on demand. Test-only;
/// single-threaded use, hence @unchecked Sendable.
final class FakeDiarizationProvider: DiarizationProvider, @unchecked Sendable {
    var prepareCount = 0
    var diarizeCalls: [URL] = []
    var turnsToReturn: [DiarizationTurn] = []
    var diarizeError: Error?

    func prepareModels() async throws { prepareCount += 1 }

    func diarize(audioPath: URL) async throws -> [DiarizationTurn] {
        diarizeCalls.append(audioPath)
        if let diarizeError { throw diarizeError }
        return turnsToReturn
    }
}

struct DiarizationServiceErr: Error {}

@Suite("DiarizationService")
struct DiarizationServiceTests {
    /// Fresh temp dir + a session whose audio lives in it.
    private func makeFixture(type: String) throws -> (URL, Session) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = Session(
            id: "sess", title: "t", sourceApp: "s", startedAt: Date(),
            audioPath: dir.appendingPathComponent("sess.wav").path,
            recordingType: type, status: "completed"
        )
        try Data().write(to: URL(fileURLWithPath: session.audioPath))
        return (dir, session)
    }

    @Test @available(macOS 14.2, *) func skipsWhenTypeDoesNotDiarize() async throws {
        let (dir, session) = try makeFixture(type: "voice_memo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeDiarizationProvider()
        fake.turnsToReturn = [DiarizationTurn(speaker: "Speaker 1", start: 0, end: 1)]
        let service = DiarizationService(provider: fake)

        await service.diarizeIfNeeded(session: session, modelsReady: true)

        #expect(fake.diarizeCalls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("sess_diarization.json").path))
    }

    @Test @available(macOS 14.2, *) func skipsWhenModelsNotReady() async throws {
        let (dir, session) = try makeFixture(type: "call_meeting")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeDiarizationProvider()
        let service = DiarizationService(provider: fake)

        await service.diarizeIfNeeded(session: session, modelsReady: false)

        #expect(fake.diarizeCalls.isEmpty)
    }

    @Test @available(macOS 14.2, *) func diarizesSystemStemWhenPresent() async throws {
        let (dir, session) = try makeFixture(type: "call_meeting")
        defer { try? FileManager.default.removeItem(at: dir) }
        let systemURL = dir.appendingPathComponent("sess_system.wav")
        try Data().write(to: systemURL)
        let fake = FakeDiarizationProvider()
        fake.turnsToReturn = [DiarizationTurn(speaker: "Speaker 1", start: 0, end: 2)]
        let service = DiarizationService(provider: fake)

        await service.diarizeIfNeeded(session: session, modelsReady: true)

        #expect(fake.diarizeCalls == [systemURL])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sess_system_diarization.json").path))
    }

    @Test @available(macOS 14.2, *) func diarizesMixedFileWhenNoStem() async throws {
        let (dir, session) = try makeFixture(type: "call_meeting")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeDiarizationProvider()
        fake.turnsToReturn = [DiarizationTurn(speaker: "Speaker 1", start: 0, end: 2)]
        let service = DiarizationService(provider: fake)

        await service.diarizeIfNeeded(session: session, modelsReady: true)

        #expect(fake.diarizeCalls == [URL(fileURLWithPath: session.audioPath)])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sess_diarization.json").path))
    }

    @Test @available(macOS 14.2, *) func prepareModelsDelegatesToProvider() async throws {
        let fake = FakeDiarizationProvider()
        let service = DiarizationService(provider: fake)
        try await service.prepareModels()
        #expect(fake.prepareCount == 1)
    }

    @Test @available(macOS 14.2, *) func swallowsProviderErrorAndWritesNoSidecar() async throws {
        let (dir, session) = try makeFixture(type: "call_meeting")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeDiarizationProvider()
        fake.diarizeError = DiarizationServiceErr()
        let service = DiarizationService(provider: fake)

        await service.diarizeIfNeeded(session: session, modelsReady: true)

        #expect(fake.diarizeCalls.count == 1)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("sess_diarization.json").path))
    }
}
