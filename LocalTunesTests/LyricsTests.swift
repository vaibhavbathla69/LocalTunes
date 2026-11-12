import XCTest
@testable import LocalTunes

final class LyricsTests: XCTestCase {
    func testFractionsMultipleTagsAndOffset() {
        let parsed = LyricsParser.parse("[offset:-500]\n[00:01.50][00:04.005]Repeat\n[00:02]Middle")
        XCTAssertEqual(parsed.lines.map(\.time), [1.0, 1.5, 3.505])
        XCTAssertEqual(parsed.lines.map(\.text), ["Repeat", "Middle", "Repeat"])
        XCTAssertNil(parsed.activeIndex(at: 0.9))
        XCTAssertEqual(parsed.activeIndex(at: 1.0), 0)
        XCTAssertEqual(parsed.activeIndex(at: 1.6), 1)
        XCTAssertEqual(parsed.activeIndex(at: 99), 2)
    }
    func testMalformedAndPlainTextGracefullyRemainReadable() {
        let text = "[ar:Artist]\n[00:99]Invalid\nOrdinary text"
        let result = LyricsParser.parse(text)
        XCTAssertFalse(result.isSynchronized)
        XCTAssertEqual(result.plainText, text)
        XCTAssertFalse(LyricsParser.parse("").isSynchronized)
        XCTAssertNil(result.activeIndex(at: .nan))
    }
    func testCoTimedTranslationsAndUnsortedInput() {
        let parsed = LyricsParser.parse("[00:05]Later\n[00:01]Hello\n[00:01.00]Bonjour")
        XCTAssertEqual(parsed.lines.count, 2)
        XCTAssertEqual(parsed.lines[0].text, "Hello\nBonjour")
        XCTAssertEqual(parsed.lines[1].time, 5)
    }
    func testNegativeOffsetClampsAtZeroAndHandlesBOM() {
        let parsed = LyricsParser.parse("\u{FEFF}[offset:-2000]\r\n[00:01.20]Start")
        XCTAssertEqual(parsed.lines.first?.time, 0)
    }
}
