import Foundation
import Testing
@testable import CallCapture

@Suite("SessionManager.updateSessionCost")
struct SessionManagerCostTests {
    @Test("cost fields round-trip through the session row")
    func roundTrips() throws {
        let path = NSTemporaryDirectory() + "cc-cost-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try AppDatabase(path: path)
        let manager = SessionManager(database: db)

        let session = manager.createSession(sourceApp: "Test", recordingType: .callMeeting)
        // A freshly-created session has no cost yet.
        #expect(manager.session(id: session.id)?.costTranscription == nil)
        #expect(manager.session(id: session.id)?.costProcessing == nil)
        #expect(manager.session(id: session.id)?.costCurrency == nil)

        manager.updateSessionCost(
            id: session.id,
            costTranscription: 0.07,
            costProcessing: 0.0123,
            costCurrency: "USD"
        )

        // Reload from the DB via a fresh fetch so we exercise the
        // SessionRecord <-> Session column mapping, not in-memory state.
        let reloaded = manager.session(id: session.id)
        #expect(reloaded?.costTranscription == 0.07)
        #expect(reloaded?.costProcessing == 0.0123)
        #expect(reloaded?.costCurrency == "USD")
    }

    @Test("unknown id is a no-op and does not crash")
    func unknownId() throws {
        let path = NSTemporaryDirectory() + "cc-cost-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try AppDatabase(path: path)
        let manager = SessionManager(database: db)
        manager.updateSessionCost(
            id: "does-not-exist",
            costTranscription: 1.0,
            costProcessing: 2.0,
            costCurrency: "USD"
        )
        #expect(manager.session(id: "does-not-exist") == nil)
    }
}
