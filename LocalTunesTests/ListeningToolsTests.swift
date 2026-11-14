import XCTest
import Network
@testable import LocalTunes

final class ListeningToolsTests: XCTestCase {
    private func fixture() throws -> (URL, LibraryPaths, LibraryDatabase) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = try LibraryPaths(documents: root)
        return (root, paths, try LibraryDatabase(url: paths.database))
    }
    private func song(_ id: String) -> Song {
        Song(id: id, relativePath: "Music/\(id).flac", originalFilename: "\(id).flac", fingerprint: id, title: id, artist: "Artist", album: "Album", genre: "Pop", trackNumber: 1, duration: 100, byteCount: 100, addedAt: Date(), year: 2015)
    }
    func testCustomMixCombinesRulesAndRefreshesAfterPlayback() async throws {
        let (root, _, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var a = song("a"); a.isFavourite = true
        var b = song("b"); b.isFavourite = true; b.genre = "Rock"
        var c = song("c"); c.isFavourite = true; c.year = 2025
        for item in [a, b, c, song("d")] { try await db.save(item) }
        var rule = SmartMixRule(); rule.genre = "Pop"; rule.fromYear = 2010; rule.throughYear = 2020; rule.favouritesOnly = true; rule.unplayedOnly = true
        let first = try await db.smartMixIDs(rule); XCTAssertEqual(first, ["a"])
        try await db.recordPlay("a")
        let next = try await db.smartMixIDs(rule); XCTAssertTrue(next.isEmpty)
        try await db.setState("smart.mixes", value: [rule])
        let restored = try await db.state("smart.mixes", as: [SmartMixRule].self)
        XCTAssertEqual(restored?.first?.genre, "Pop")
    }
    func testListeningVisitsCoalesceAndSurviveSongRemovalUntilHistoryClear() async throws {
        let (root, _, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await db.save(song("a"))
        try await db.recordListening("a", seconds: 20, plays: 0, entryID: "entry")
        try await db.recordListening("a", seconds: 30, plays: 1, entryID: "entry")
        let sessions = try await db.listeningSessions()
        XCTAssertEqual(sessions.count, 1); XCTAssertEqual(sessions.first?.visits.count, 1); XCTAssertEqual(sessions.first?.seconds, 50)
        try await db.remove("a")
        let retained = try await db.listeningSessions(); XCTAssertEqual(retained.first?.visits.first?.title, "a")
        try await db.clearListening()
        let cleared = try await db.listeningSessions(); XCTAssertTrue(cleared.isEmpty)
    }
    func testSessionGapAndVisitOrder() {
        func visit(_ id: String, _ time: Double) -> ListeningVisit { ListeningVisit(id: id, songID: id, title: id, artist: "Artist", started: Date(timeIntervalSince1970: time), ended: Date(timeIntervalSince1970: time + 10), seconds: 10) }
        let sessions = ListeningSession.group([visit("c", 1900), visit("b", 20), visit("a", 0)])
        XCTAssertEqual(sessions.count, 2); XCTAssertEqual(sessions[0].visits.map(\.id), ["c"]); XCTAssertEqual(sessions[1].visits.map(\.id), ["a", "b"])
    }
    func testBookmarksPersistAndLyricTimingRoundTrips() async throws {
        let (root, _, db) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bookmark = PlaybackBookmark(songID: "a", title: "Bridge", seconds: 62.5)
        try await db.setState("playback.bookmarks", value: [bookmark])
        let saved = try await db.state("playback.bookmarks", as: [PlaybackBookmark].self)
        XCTAssertEqual(saved?.first?.seconds, 62.5)
        let lrc = LyricTiming.lrc(lines: ["One", "Two"], times: [1, 62.25], offset: -0.5)
        let parsed = LyricsParser.parse(lrc)
        XCTAssertEqual(parsed.lines.map(\.time), [0.5, 61.75]); XCTAssertEqual(parsed.lines.map(\.text), ["One", "Two"])
    }
    func testCustomAccentContrastOnBothSurfaces() {
        for dark in [false, true] {
            for hex in ["000000", "FFFFFF", "FFFF00", "000088", "FA243C"] {
                let rgb = ThemeContrast.components(hex, dark: dark)
                let l = ThemeContrast.luminance(rgb)
                XCTAssertGreaterThanOrEqual(dark ? (l + 0.05) / 0.05 : 1.05 / (l + 0.05), 4.5)
            }
        }
    }
    func testUploadResumeChecksumsAndCompletion() async throws {
        let (root, paths, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try WiFiUploadStore(paths: paths)
        let first = Data(repeating: 42, count: WiFiUploadStore.chunkSize), last = Data("last part".utf8)
        let created = try await store.begin(name: "Song.flac", size: Int64(first.count + last.count), modified: "1", relative: "Album/Song.flac")
        _ = try await store.append(id: created.id, offset: 0, data: first, hash: WiFiUploadStore.digest(first))
        let reopened = try WiFiUploadStore(paths: paths)
        let resumed = try await reopened.begin(name: "Song.flac", size: Int64(first.count + last.count), modified: "1", relative: "Album/Song.flac")
        XCTAssertEqual(resumed.offset, Int64(first.count)); XCTAssertEqual(resumed.id, created.id)
        do { _ = try await reopened.append(id: created.id, offset: resumed.offset, data: last, hash: "bad"); XCTFail("Reject checksum mismatch") } catch { }
        _ = try await reopened.append(id: created.id, offset: resumed.offset, data: last, hash: WiFiUploadStore.digest(last))
        let url = try await reopened.finish(id: created.id)
        XCTAssertEqual(try Data(contentsOf: url), first + last)
        try await reopened.clearPartials(); XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    func testUploadsRejectTraversalAndRepairCorruptResume() async throws {
        let (root, paths, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try WiFiUploadStore(paths: paths)
        do { _ = try await store.begin(name: "../Song.flac", size: 8, modified: "1", relative: "x"); XCTFail("Reject traversal") } catch { }
        let data = Data(repeating: 3, count: WiFiUploadStore.chunkSize)
        let upload = try await store.begin(name: "Song.flac", size: Int64(data.count + 1), modified: "1", relative: "Song.flac")
        _ = try await store.append(id: upload.id, offset: 0, data: data, hash: WiFiUploadStore.digest(data))
        let partial = paths.support.appendingPathComponent("WiFiUploads/\(upload.id).part")
        try Data("corrupt".utf8).write(to: partial)
        let repaired = try await store.begin(name: "Song.flac", size: Int64(data.count + 1), modified: "1", relative: "Song.flac")
        XCTAssertEqual(repaired.offset, 0)
        do { _ = try await store.finish(id: upload.id); XCTFail("Incomplete uploads must not appear in Import") } catch { }
    }
    @MainActor
    func testLocalHTTPRequiresAddressSecretAndIncludesBrowserClient() async throws {
        let (root, paths, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = WiFiTransferService(); defer { service.stop() }
        await service.start(paths, testAddress: "127.0.0.1")
        for _ in 0..<200 { if service.address != nil { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        let address = try XCTUnwrap(service.address), url = try XCTUnwrap(URL(string: address))
        let page = try await HTTPProbe.get(url: url)
        XCTAssertTrue(page.contains("200 Response")); XCTAssertTrue(page.contains("LocalTunes Transfer"))
        let script = try await HTTPProbe.get(url: url.appendingPathComponent("client.js"))
        XCTAssertTrue(script.contains("function sha256"))
        var wrong = URLComponents(url: url, resolvingAgainstBaseURL: false)!; wrong.path = "/wrong/"
        let denied = try await HTTPProbe.get(url: wrong.url!)
        XCTAssertTrue(denied.contains("404 Response"))
        let content = Data("wire test".utf8)
        let beginBody = try JSONSerialization.data(withJSONObject: ["name":"Tone.flac", "size":content.count, "modified":"1", "relative":"Tone.flac"])
        let response = try await HTTPProbe.request(url: url.appendingPathComponent("begin"), method: "POST", body: beginBody)
        let payload = try XCTUnwrap(response.components(separatedBy: "\r\n\r\n").last?.data(using: .utf8))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let uploadID = try XCTUnwrap(json["id"] as? String)
        var chunk = URLComponents(url: url.appendingPathComponent("chunk"), resolvingAgainstBaseURL: false)!
        chunk.queryItems = [URLQueryItem(name: "id", value: uploadID), URLQueryItem(name: "offset", value: "0")]
        let accepted = try await HTTPProbe.request(url: chunk.url!, method: "POST", body: content, extra: "X-Chunk-SHA256: " + WiFiUploadStore.digest(content) + "\r\n")
        XCTAssertTrue(accepted.contains("200 Response"))
        var finish = URLComponents(url: url.appendingPathComponent("finish"), resolvingAgainstBaseURL: false)!
        finish.queryItems = [URLQueryItem(name: "id", value: uploadID)]
        let complete = try await HTTPProbe.request(url: finish.url!, method: "POST")
        XCTAssertTrue(complete.contains("200 Response")); XCTAssertEqual(service.received.count, 1)
        XCTAssertEqual(try Data(contentsOf: service.received[0]), content)
    }
}

private final class HTTPProbe: @unchecked Sendable {
    private let connection: NWConnection
    private var continuation: CheckedContinuation<String, Error>?
    private var data = Data()
    private let queue = DispatchQueue(label: "LocalTunes.HTTPTest")
    private init(url: URL) {
        connection = NWConnection(host: NWEndpoint.Host(url.host!), port: NWEndpoint.Port(rawValue: UInt16(url.port!))!, using: .tcp)
    }
    static func get(url: URL) async throws -> String { try await request(url: url) }
    static func request(url: URL, method: String = "GET", body: Data = Data(), extra: String = "") async throws -> String {
        let probe = HTTPProbe(url: url)
        return try await withCheckedThrowingContinuation { continuation in
            probe.continuation = continuation
            probe.connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    probe.connection.stateUpdateHandler = nil
                    let path = (url.path.hasSuffix("/") ? url.path : url.path + (url.path.hasSuffix(".js") ? "" : "/")) + (url.query.map { "?" + $0 } ?? "")
                    let header = "\(method) \(path) HTTP/1.1\r\nHost: \(url.host!):\(url.port!)\r\nContent-Length: \(body.count)\r\n\(extra)Connection: close\r\n\r\n"
                    var request = Data(header.utf8); request.append(body)
                    probe.connection.send(content: request, completion: .contentProcessed { error in if let error { probe.finish(.failure(error)) } else { probe.receive() } })
                case .failed(let error): probe.finish(.failure(error))
                default: break
                }
            }
            probe.connection.start(queue: probe.queue)
            probe.queue.asyncAfter(deadline: .now() + 20) { if probe.continuation != nil { probe.finish(.failure(URLError(.timedOut))) } }
        }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { bytes, _, complete, error in
            if let bytes { self.data.append(bytes) }
            if let error { self.finish(.failure(error)) }
            else if complete { self.finish(.success(String(decoding: self.data, as: UTF8.self))) }
            else { self.receive() }
        }
    }
    private func finish(_ result: Result<String, Error>) { let callback = continuation; continuation = nil; connection.stateUpdateHandler = nil; connection.cancel(); callback?.resume(with: result) }
}
