import Foundation
import Testing
@testable import CallCapture

@Suite("SessionManager.updateRecordingType")
struct SessionManagerRecordingTypeTests {
    @Test("persists a new recording type to the database")
    func persists() throws {
        let path = NSTemporaryDirectory() + "cc-sm-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try AppDatabase(path: path)
        let manager = SessionManager(database: db)

        let session = manager.createSession(sourceApp: "Test", recordingType: .callMeeting)
        #expect(manager.session(id: session.id)?.recordingType == "call_meeting")

        manager.updateRecordingType(id: session.id, recordingType: "lecture")
        #expect(manager.session(id: session.id)?.recordingType == "lecture")
    }

    @Test("unknown id is a no-op and does not crash")
    func unknownId() throws {
        let path = NSTemporaryDirectory() + "cc-sm-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try AppDatabase(path: path)
        let manager = SessionManager(database: db)

        manager.updateRecordingType(id: "does-not-exist", recordingType: "lecture")
        #expect(manager.session(id: "does-not-exist") == nil)
    }
}
