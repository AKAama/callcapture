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

    @Test("原子清空并结束后不重新接收残留回调数据")
    func discardsAndFinishesAtomically() {
        let buffer = PCMChunkBuffer(capacity: 2)
        #expect(buffer.push(Data([1])) == 0)

        buffer.discardAndFinish()

        #expect(buffer.push(Data([2])) == 1)
        #expect(buffer.pop() == nil)
        #expect(buffer.discardedCount == 1)
        #expect(buffer.isFinishedAndEmpty)
    }

    @Test("重连隔离点会清空已排队音频并计入降级数")
    func discardsQueuedAudioAtReconnectBarrier() {
        let buffer = PCMChunkBuffer(capacity: 4)
        #expect(buffer.push(Data([1])) == 0)
        #expect(buffer.push(Data([2])) == 0)

        #expect(buffer.discardQueued() == 2)
        #expect(buffer.pop() == nil)
        #expect(buffer.discardedCount == 2)

        buffer.recordDiscarded(1)
        #expect(buffer.discardedCount == 3)
        #expect(buffer.push(Data([3])) == 0)
        #expect(buffer.pop() == Data([3]))
    }
}
