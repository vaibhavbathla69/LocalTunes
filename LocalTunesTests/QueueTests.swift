import XCTest
@testable import LocalTunes

final class QueueTests: XCTestCase {
    func testPlayNextPreservesCurrentAndSupportsDuplicateSongs() {
        var queue = PlaybackQueue()
        queue.replace(["a", "b"], startAt: 0)
        let current = queue.currentID
        queue.append("a", next: true)
        XCTAssertEqual(queue.currentID, current)
        XCTAssertEqual(queue.entries.map(\.songID), ["a", "a", "b"])
        XCTAssertEqual(Set(queue.entries.map(\.id)).count, 3)
    }

    func testRepeatModesAndRemoval() {
        var queue = PlaybackQueue()
        queue.replace(["a", "b"], startAt: 1)
        XCTAssertNil(queue.following(automatic: true))
        queue.repeatMode = .all
        XCTAssertEqual(queue.following(automatic: true)?.songID, "a")
        queue.repeatMode = .one
        XCTAssertEqual(queue.following(automatic: true)?.songID, "b")
        queue.remove(entryIDs: Set([queue.currentID!]))
        XCTAssertEqual(queue.current?.songID, "a")
    }

    func testShuffleRoundTripRetainsCurrentIdentity() {
        var queue = PlaybackQueue()
        queue.replace(["a", "b", "c", "d"], startAt: 1)
        let before = queue.entries
        let current = queue.currentID
        queue.toggleShuffle()
        XCTAssertEqual(queue.currentID, current)
        queue.toggleShuffle()
        XCTAssertEqual(queue.entries, before)
    }

    func testMoveAndPersistenceRoundTrip() throws {
        var queue = PlaybackQueue()
        queue.replace(["a", "b", "c"], startAt: 1)
        queue.move(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(queue.entries.map(\.songID), ["c", "a", "b"])
        XCTAssertEqual(queue.current?.songID, "b")
        XCTAssertEqual(try JSONDecoder().decode(PlaybackQueue.self, from: JSONEncoder().encode(queue)), queue)
    }
}
