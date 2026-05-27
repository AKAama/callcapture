import Foundation
import Testing
@testable import CallCapture

@Suite("InsightsFormat")
struct InsightsFormatTests {
    @Test("percent rounds and clamps to 0...100")
    func percent() {
        #expect(InsightsFormat.percent(0.6) == "60%")
        #expect(InsightsFormat.percent(1.0) == "100%")
        #expect(InsightsFormat.percent(0.0) == "0%")
        #expect(InsightsFormat.percent(0.404) == "40%")
        #expect(InsightsFormat.percent(1.5) == "100%")
        #expect(InsightsFormat.percent(-0.2) == "0%")
    }

    @Test("signed formats with an explicit sign")
    func signed() {
        #expect(InsightsFormat.signed(0.5) == "+0.50")
        #expect(InsightsFormat.signed(0.0) == "+0.00")
        #expect(InsightsFormat.signed(-0.2, fractionDigits: 1) == "-0.2")
        #expect(InsightsFormat.signed(0.6, fractionDigits: 1) == "+0.6")
    }
}
