import Foundation
import Testing
import GRDB
@testable import CallCapture

@Suite("Database migration")
struct DatabaseMigrationTests {
    @Test("session table has recording_type and analysis_path columns")
    func newColumnsExist() throws {
        let dir = NSTemporaryDirectory()
        let path = dir + "cc-test-\(UUID().uuidString).db"
        let db = try AppDatabase(path: path)
        let columns = try db.dbPool.read { database in
            try database.columns(in: "session").map(\.name)
        }
        #expect(columns.contains("recording_type"))
        #expect(columns.contains("analysis_path"))
        try? FileManager.default.removeItem(atPath: path)
    }
}
