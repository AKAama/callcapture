import Foundation
import Testing
@testable import CallCapture

@Suite("Pricing settings")
struct PricingSettingsTests {

    /// Builds a SettingsManager on a fresh temp DB. Returns the manager plus the
    /// backing AppDatabase so a reload can reuse the same store.
    private func makeSettings() throws -> (settings: SettingsManager, db: AppDatabase, path: String) {
        let path = NSTemporaryDirectory() + "cc-pricing-\(UUID().uuidString).db"
        let db = try AppDatabase(path: path)
        return (SettingsManager(database: db), db, path)
    }

    /// Constructs a new SettingsManager on the same DB to verify persisted reload.
    private func reloadSettings(_ db: AppDatabase) -> SettingsManager {
        SettingsManager(database: db)
    }

    @Test("default rates are seeded to the worker's pricing.py defaults")
    func defaultRatesSeeded() throws {
        let (s, _, path) = try makeSettings()
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(abs(s.sttRateAssemblyAI - 0.0035) < 1e-9)
        #expect(abs(s.sttRateDeepgram - 0.0043) < 1e-9)
        #expect(abs(s.sttRateOpenAI - 0.0060) < 1e-9)
        #expect(abs(s.sttRateGroq - 0.0007) < 1e-9)
        #expect(abs(s.llmFallbackRatePer1M - 3.00) < 1e-9)
    }

    @Test("a changed rate persists and reloads from the DB")
    func ratePersistsAndReloads() throws {
        let (s, db, path) = try makeSettings()
        defer { try? FileManager.default.removeItem(atPath: path) }
        s.sttRateAssemblyAI = 0.01
        let reloaded = reloadSettings(db)
        #expect(abs(reloaded.sttRateAssemblyAI - 0.01) < 1e-9)
    }

    @Test("resetPricingToDefaults restores the seeded defaults")
    func resetRestoresDefaults() throws {
        let (s, _, path) = try makeSettings()
        defer { try? FileManager.default.removeItem(atPath: path) }
        s.sttRateAssemblyAI = 0.99
        s.resetPricingToDefaults()
        #expect(abs(s.sttRateAssemblyAI - 0.0035) < 1e-9)
    }
}
