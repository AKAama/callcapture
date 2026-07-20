import Foundation
import Testing
@testable import CallCapture

@Suite("PCMChunkBuffer")
struct PCMChunkBufferTests {
    @Test("满载时丢弃最旧数据")
    func dropsOldest() {
        let buffer = PCMChunkBuffer(capacity: 2)

        #expect(buffer.push(Data([1])) == 0)
        #expect(buffer.push(Data([2])) == 0)
        #expect(buffer.push(Data([3])) == 1)
        #expect(buffer.pop() == Data([2]))
        #expect(buffer.pop() == Data([3]))
    }
}
