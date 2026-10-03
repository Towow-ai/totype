import Foundation

/// Coalesces tiny PCM callback buffers into network-sized frames without
/// dropping, duplicating, or reordering any byte.
public struct PCMFrameBatcher: Sendable {
    public let targetFrameBytes: Int
    private var buffered = Data()

    public init(targetFrameBytes: Int) {
        precondition(targetFrameBytes > 0)
        self.targetFrameBytes = targetFrameBytes
    }

    public var bufferedByteCount: Int { buffered.count }

    public mutating func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        buffered.append(data)

        var frames: [Data] = []
        var offset = 0
        while buffered.count - offset >= targetFrameBytes {
            let end = offset + targetFrameBytes
            frames.append(buffered.subdata(in: offset..<end))
            offset = end
        }
        if offset > 0 {
            buffered.removeSubrange(0..<offset)
        }
        return frames
    }

    public mutating func flush() -> Data? {
        guard !buffered.isEmpty else { return nil }
        let tail = buffered
        buffered.removeAll(keepingCapacity: true)
        return tail
    }

    public mutating func reset() {
        buffered.removeAll(keepingCapacity: true)
    }
}
