import Foundation

/// A thread-safe, bounded FIFO queue for PCM chunks awaiting transmission.
///
/// When the queue is full, `push(_:)` evicts the oldest chunk so an audio
/// capture callback can keep running without blocking or growing memory.
final class PCMChunkBuffer: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var isFinished = false

    init(capacity: Int) {
        precondition(capacity > 0, "PCMChunkBuffer capacity must be positive")
        self.capacity = capacity
        chunks.reserveCapacity(capacity)
    }

    /// Enqueues a chunk without waiting for the buffer lock.
    ///
    /// Returns one when either the oldest queued chunk was evicted at capacity
    /// or the incoming chunk was discarded because another operation holds the
    /// lock. Returns zero otherwise, including when the buffer is finished.
    func push(_ data: Data) -> Int {
        guard lock.try() else { return 1 }
        defer { lock.unlock() }

        guard !isFinished else { return 0 }

        let discarded = chunks.count == capacity ? 1 : 0
        if discarded == 1 {
            chunks.removeFirst()
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

    /// Discards queued chunks and resets the buffer for a future session.
    func clear() {
        lock.lock()
        defer { lock.unlock() }

        chunks.removeAll(keepingCapacity: true)
        isFinished = false
    }
}
