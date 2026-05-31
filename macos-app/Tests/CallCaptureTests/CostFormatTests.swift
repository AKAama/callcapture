import Foundation
import Testing
@testable import CallCapture

@Suite("CostFormat")
struct CostFormatTests {
    @Test("formats USD to four decimal places")
    func formatsToFourDecimals() {
        #expect(CostFormat.usd(0.0123) == "$0.0123")
        #expect(CostFormat.usd(0.07) == "$0.0700")
    }

    @Test("zero renders as $0.0000")
    func zeroRendersAsZero() {
        #expect(CostFormat.usd(0.0) == "$0.0000")
    }

    @Test("nil renders as an em dash")
    func nilRendersDash() {
        #expect(CostFormat.usd(nil) == "—")
    }

    @Test("total sums the parts, nil only when both nil")
    func totalSumsParts() {
        let sum = CostFormat.total(0.07, 0.0123)
        #expect(sum != nil)
        #expect(abs((sum ?? 0) - 0.0823) < 1e-9)
        #expect(CostFormat.total(nil, nil) == nil)
    }

    @Test("total treats a nil part as zero when the other is present")
    func totalNilPartIsZero() {
        #expect(CostFormat.total(0.05, nil) == 0.05)
        #expect(CostFormat.total(nil, 0.05) == 0.05)
    }
}
