import Foundation

public struct BoundedByteRing: Sendable {
    private var storage = Data()
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(0, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public mutating func append(_ data: Data) {
        guard capacity > 0, !data.isEmpty else { return }
        storage.append(data)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    public func snapshot() -> Data {
        storage
    }

    public mutating func removeAll(keepingCapacity: Bool = true) {
        storage.removeAll(keepingCapacity: keepingCapacity)
    }
}

/// Retains a short, ordered hand-off window while an eventual consumer is
/// still being constructed. Sequence filtering joins an earlier snapshot to
/// later live values without either a gap or duplicate boundary values.
public struct SequencedCaptureBuffer<Element: Sendable>: Sendable {
    private struct Entry: Sendable {
        let sequence: Int64
        let element: Element
    }

    private var accepting = false
    private var entries: [Entry] = []

    public init() {}

    public mutating func begin() {
        accepting = true
        entries.removeAll(keepingCapacity: true)
    }

    public mutating func append(_ element: Element, sequence: Int64) {
        guard accepting else { return }
        entries.append(Entry(sequence: sequence, element: element))
    }

    public mutating func end() {
        accepting = false
    }

    public mutating func drain(after sequence: Int64) -> [Element] {
        accepting = false
        let result = entries
            .filter { $0.sequence > sequence }
            .sorted { $0.sequence < $1.sequence }
            .map(\.element)
        entries.removeAll(keepingCapacity: false)
        return result
    }

    public mutating func cancel() {
        accepting = false
        entries.removeAll(keepingCapacity: false)
    }
}
