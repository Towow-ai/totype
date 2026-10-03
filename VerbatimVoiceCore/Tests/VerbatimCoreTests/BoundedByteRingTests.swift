import XCTest
@testable import VerbatimCore

final class BoundedByteRingTests: XCTestCase {
    func testKeepsNewestBytesOnly() {
        var ring = BoundedByteRing(capacity: 5)
        ring.append(Data([1, 2, 3]))
        ring.append(Data([4, 5, 6]))
        XCTAssertEqual(Array(ring.snapshot()), [2, 3, 4, 5, 6])
    }

    func testSequencedCaptureJoinsSnapshotWithoutGapOrDuplicate() {
        var buffer = SequencedCaptureBuffer<String>()
        buffer.begin()
        buffer.append("snapshot-tail", sequence: 10)
        buffer.append("opening", sequence: 11)
        buffer.append("next", sequence: 12)
        buffer.end()
        buffer.append("after-release", sequence: 13)

        XCTAssertEqual(buffer.drain(after: 10), ["opening", "next"])
    }

    func testSequencedCaptureCancelDiscardsPendingValues() {
        var buffer = SequencedCaptureBuffer<String>()
        buffer.begin()
        buffer.append("discard", sequence: 1)
        buffer.cancel()

        XCTAssertEqual(buffer.drain(after: 0), [])
    }
}
