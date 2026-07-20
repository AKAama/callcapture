import Foundation
import Testing
@testable import CallCapture

@Suite("PCMChunkBuffer")
struct PCMChunkBufferTests {
    @Test("满载时丢弃最旧数据并报告一次丢弃")
    func dropsOldestAndReportsDiscard() {
        let buffer = PCMChunkBuffer(capacity: 2)

        #expect(buffer.push(Data([1])) == 0)
        #expect(buffer.push(Data([2])) == 0)
        #expect(buffer.push(Data([3])) == 1)
        #expect(buffer.pop() == Data([2]))
        #expect(buffer.pop() == Data([3]))
    }

    @Test("结束后丢弃新数据并报告一次丢弃")
    func dropsIncomingDataAfterFinish() {
        let buffer = PCMChunkBuffer(capacity: 2)
        #expect(buffer.push(Data([1])) == 0)

        buffer.finish()

        #expect(buffer.push(Data([2])) == 1)
        #expect(buffer.pop() == Data([1]))
        #expect(buffer.pop() == nil)
    }
}
