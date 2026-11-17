import XCTest
@testable import LocalTunes

final class QueueTests: XCTestCase {
    func testPlayNextIsFIFOAndSurvivesRestoreAndShuffle() throws {
        var queue = PlaybackQueue()
        queue.replace(["current", "album1", "album2"], startAt: 0)
        queue.append("first", next: true)
        queue.append("second", next: true)
        queue = try JSONDecoder().decode(PlaybackQueue.self, from: JSONEncoder().encode(queue))
        queue.append("third", next: true)
        XCTAssertEqual(queue.entries.map(\.songID), ["current", "first", "second", "third", "album1", "album2"])
        queue.toggleShuffle()
        XCTAssertEqual(Array(queue.entries.prefix(4)).map(\.songID), ["current", "first", "second", "third"])
        queue.toggleShuffle()
        XCTAssertEqual(queue.entries.map(\.songID), ["current", "first", "second", "third", "album1", "album2"])
    }

    func testPlayNextContinuesAfterRemainingBatchAndHandlesRemovalAndReplacement() {
        var queue = PlaybackQueue()
        queue.replace(["current", "album"], startAt: 0)
        queue.append("first", next: true)
        let second = queue.append("second", next: true)
        queue.currentID = queue.following(automatic: false)?.id
        queue.append("third", next: true)
        XCTAssertEqual(queue.entries.map(\.songID), ["current", "first", "second", "third", "album"])
        queue.remove(entryIDs: [second])
        queue.append("fourth", next: true)
        XCTAssertEqual(queue.entries.map(\.songID), ["current", "first", "third", "fourth", "album"])
        queue.currentID = queue.entries.last?.id
        queue.append("new batch", next: true)
        XCTAssertEqual(queue.following(automatic: false)?.songID, "new batch")
        queue.replace(["replacement", "rest"], startAt: 0)
        queue.append("next", next: true)
        XCTAssertEqual(queue.entries.map(\.songID), ["replacement", "next", "rest"])
    }

    func testOldQueueDecodesWithoutPlayNextMetadata() throws {
        var queue = PlaybackQueue()
        queue.replace(["a", "b"], startAt: 0)
        let data = try JSONEncoder().encode(queue)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "playNextEntryIDs")
        var restored = try JSONDecoder().decode(PlaybackQueue.self, from: JSONSerialization.data(withJSONObject: object))
        restored.append("c", next: true); restored.append("d", next: true)
        XCTAssertEqual(restored.entries.map(\.songID), ["a", "c", "d", "b"])
    }

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
