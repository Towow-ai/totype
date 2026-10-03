import Foundation

final class AudioRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var ring: BoundedByteRing
    private var capacityBytes: Int

    init(capacityBytes: Int) {
        self.capacityBytes = capacityBytes
        ring = BoundedByteRing(capacity: capacityBytes)
    }

    func append(_ data: Data) {
        lock.lock()
        ring.append(data)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return ring.snapshot()
    }

    func resize(capacityBytes: Int) {
        lock.lock()
        let existing = ring.snapshot()
        self.capacityBytes = capacityBytes
        ring = BoundedByteRing(capacity: capacityBytes)
        ring.append(existing)
        lock.unlock()
    }

    /// Starts a new capture boundary without retaining audio from an earlier
    /// dictation. Capacity is preserved so the next first-frame buffer is
    /// allocated once and remains bounded.
    func clear() {
        lock.lock()
        ring = BoundedByteRing(capacity: capacityBytes)
        lock.unlock()
    }
}
