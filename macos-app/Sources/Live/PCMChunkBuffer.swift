import Foundation
import Darwin

/// A thread-safe, bounded FIFO queue for PCM chunks awaiting transmission.
///
/// When the queue is full, `push(_:)` evicts the oldest chunk so an audio
/// capture callback can keep running without blocking or growing memory.
final class PCMChunkBuffer: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var isFinished = false
    private var totalDiscarded: Int64 = 0

    init(capacity: Int) {
        precondition(capacity > 0, "PCMChunkBuffer capacity must be positive")
        self.capacity = capacity
        chunks.reserveCapacity(capacity)
    }

    /// Enqueues a chunk without waiting for the buffer lock.
    ///
    /// Returns one when either the oldest queued chunk was evicted at capacity
    /// or the incoming chunk was discarded because another operation holds the
    /// lock or the buffer is finished. Returns zero otherwise.
    func push(_ data: Data) -> Int {
        guard lock.try() else {
            recordDiscard()
            return 1
        }
        defer { lock.unlock() }

        guard !isFinished else {
            recordDiscard()
            return 1
        }

        let discarded = chunks.count == capacity ? 1 : 0
        if discarded == 1 {
            chunks.removeFirst()
            recordDiscard()
        }
        chunks.append(data)
        return discarded
    }

    /// Removes and returns the oldest queued chunk, if any.
    func pop() -> Data? {
        lock.lock()
        defer { lock.unlock() }

        guard !chunks.isEmpty else { return nil }
        return chunks.removeFirst()
    }

    /// Stops accepting new chunks while preserving queued chunks for draining.
    func finish() {
        lock.lock()
        defer { lock.unlock() }

        isFinished = true
    }

    /// Atomically discards queued audio and permanently closes this session's
    /// buffer to producers. Unlike `clear()`, this never reopens the queue.
    func discardAndFinish() {
        lock.lock()
        defer { lock.unlock() }

        chunks.removeAll(keepingCapacity: true)
        isFinished = true
    }

    /// Discards queued chunks and resets the buffer for a future session.
    func clear() {
        lock.lock()
        defer { lock.unlock() }

        chunks.removeAll(keepingCapacity: true)
        isFinished = false
        resetDiscardCount()
    }

    /// Total chunks discarded since initialization or the most recent clear.
    ///
    /// The counter includes capacity eviction, finished-buffer rejection, and
    /// incoming chunks dropped because `push(_:)` could not immediately take
    /// the queue lock.
    var discardedCount: Int {
        Int(OSAtomicAdd64Barrier(0, &totalDiscarded))
    }

    /// `true` once producers have finished and every accepted chunk was read.
    var isFinishedAndEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinished && chunks.isEmpty
    }

    private func recordDiscard() {
        OSAtomicIncrement64Barrier(&totalDiscarded)
    }

    private func resetDiscardCount() {
        while true {
            let current = OSAtomicAdd64Barrier(0, &totalDiscarded)
            guard current != 0 else { return }
            if OSAtomicCompareAndSwap64Barrier(current, 0, &totalDiscarded) {
                return
            }
        }
    }
}
