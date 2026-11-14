import Foundation
import Combine
import Network
import UIKit
import Darwin

@MainActor
final class WiFiTransferService: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var address: String?
    @Published private(set) var message = "Transfer is off"
    @Published private(set) var received: [URL] = []
    private var listener: NWListener?
    private var store: WiFiUploadStore?
    private var token = ""
    private var priorIdle = false
    private struct Peer {
        var connection: NWConnection
        var buffer = Data()
        var processing = false
        var timeout: Task<Void, Never>?
    }
    private var peers: [UUID: Peer] = [:]
    func prepare(_ paths: LibraryPaths) async {
        do { if store == nil { store = try WiFiUploadStore(paths: paths) }; received = try await store?.received() ?? [] }
        catch { message = error.localizedDescription }
    }
    func start(_ paths: LibraryPaths, testAddress: String? = nil) async {
        guard listener == nil else { return }
        await prepare(paths)
        guard store != nil, let ip = testAddress ?? Self.localAddress() else { message = "Connect this iPhone to Wi-Fi first"; return }
        do {
            let parameters = NWParameters.tcp
            parameters.prohibitedInterfaceTypes = [.cellular]
            let listener = try NWListener(using: parameters, on: .any)
            self.listener = listener; token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            running = true
            priorIdle = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            message = "Starting local transfer"
            listener.stateUpdateHandler = { [weak self, weak listener] state in Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    if let port = listener.port { self.address = "http://\(ip):\(port.rawValue)/\(self.token)/"; self.running = true; self.message = "Ready for files from your PC" }
                case .failed(let error): self.stop(); self.message = error.localizedDescription
                case .waiting(let error): self.message = "Waiting for local network access: \(error.localizedDescription)"
                default: break
                }
            } }
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
            listener.start(queue: DispatchQueue(label: "LocalTunes.WiFi"))
        } catch { stop(); message = error.localizedDescription }
    }
    func stop() {
        let hadListener = listener != nil
        listener?.cancel(); listener = nil
        for id in Array(peers.keys) { close(id) }
        if hadListener { UIApplication.shared.isIdleTimerDisabled = priorIdle }
        running = false; address = nil; message = "Transfer stopped; partial progress is kept"
    }
    func clearPartials() async {
        guard listener == nil else { return }
        do { try await store?.clearPartials(); message = "Partial uploads removed" } catch { message = error.localizedDescription }
    }
    private func accept(_ connection: NWConnection) {
        guard listener != nil, peers.count < 4, Self.localPeer(connection.endpoint) else { connection.cancel(); return }
        let id = UUID()
        peers[id] = Peer(connection: connection)
        peers[id]?.timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000_000) } catch { return }
            self?.close(id)
        }
        connection.start(queue: DispatchQueue(label: "LocalTunes.WiFi.\(id)"))
        receive(id)
    }
    private func close(_ id: UUID) { peers[id]?.timeout?.cancel(); peers.removeValue(forKey: id)?.connection.cancel() }
    private func receive(_ id: UUID) {
        guard let peer = peers[id], !peer.processing else { return }
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, var state = self.peers[id] else { return }
                if let data { state.buffer.append(data) }
                self.peers[id] = state
                if self.ready(id) { self.peers[id]?.processing = true; await self.handle(id) }
                else if complete || error != nil { self.close(id) }
                else { self.receive(id) }
            }
        }
    }
    private func ready(_ id: UUID) -> Bool {
        guard let data = peers[id]?.buffer else { return false }
        guard data.count <= 2_114_560 else { respond(id, status: 413, data: Data("{}".utf8)); return false }
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16384 { respond(id, status: 431, data: Data("{}".utf8)) }
            return false
        }
        guard end.upperBound <= 16384, let text = String(data: data[..<end.lowerBound], encoding: .utf8) else { respond(id, status: 400, data: Data("{}".utf8)); return false }
        let lines = text.components(separatedBy: "\r\n")
        var length = 0
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            if pieces.first?.lowercased() == "transfer-encoding" { respond(id, status: 400, data: Data("{}".utf8)); return false }
            if pieces.first?.lowercased() == "content-length" {
                guard pieces.count == 2, let count = Int(pieces[1].trimmingCharacters(in: .whitespaces)), count >= 0, count <= 2_097_152 else { respond(id, status: 413, data: Data("{}".utf8)); return false }
                length = count
            }
        }
        return data.count >= end.upperBound + length
    }
    private func handle(_ id: UUID) async {
        guard let data = peers[id]?.buffer, let end = data.range(of: Data("\r\n\r\n".utf8)),
              let text = String(data: data[..<end.lowerBound], encoding: .utf8) else { close(id); return }
        let lines = text.components(separatedBy: "\r\n"), start = lines[0].split(separator: " ")
        guard start.count == 3, let url = URLComponents(string: "http://local" + String(start[1])) else { respondJSON(id, status: 400, value: ["error":"Invalid request"]); return }
        let components = url.path.split(separator: "/").map(String.init)
        guard components.first == token else { respondJSON(id, status: 404, value: ["error":"Open the current transfer address shown on the iPhone"]); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        if let origin = headers["origin"], origin != "http://" + (headers["host"] ?? "") { respondJSON(id, status: 403, value: ["error":"Origin not allowed"]); return }
        let body = Data(data[end.upperBound...])
        let route = components.dropFirst().joined(separator: "/")
        if start[0] == "GET", route.isEmpty {
            if !url.path.hasSuffix("/") { respond(id, status: 308, data: Data(), extra: "Location: /\(token)/\r\n"); return }
            respond(id, status: 200, data: Data(Self.page.utf8), type: "text/html; charset=utf-8"); return
        }
        if start[0] == "GET", route == "client.js" {
            guard let resource = Bundle.main.url(forResource: "Transfer", withExtension: "js"), let script = try? Data(contentsOf: resource) else { respondJSON(id, status: 500, value: ["error":"Transfer script is unavailable"]); return }
            respond(id, status: 200, data: script, type: "application/javascript; charset=utf-8"); return
        }
        guard start[0] == "POST", let store else { respondJSON(id, status: 405, value: ["error":"Unsupported request"]); return }
        let query = Dictionary(url.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { first, _ in first })
        do {
            switch route {
            case "begin":
                guard body.count <= 8192, let values = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let name = values["name"] as? String, let size = values["size"] as? NSNumber,
                      let modified = values["modified"] as? String, let relative = values["relative"] as? String else { throw LibraryError.message("Invalid file description") }
                let upload = try await store.begin(name: name, size: size.int64Value, modified: modified, relative: relative)
                respondUpload(id, upload)
            case "chunk":
                guard let uploadID = query["id"], let offset = query["offset"].flatMap(Int64.init), let hash = headers["x-chunk-sha256"] else { throw LibraryError.message("Missing chunk information") }
                let upload = try await store.append(id: uploadID, offset: offset, data: body, hash: hash)
                respondUpload(id, upload); message = "Receiving \(upload.name): \(upload.offset)/\(upload.size) bytes"
            case "finish":
                guard let uploadID = query["id"] else { throw LibraryError.message("Missing upload ID") }
                _ = try await store.finish(id: uploadID); received = try await store.received()
                respondJSON(id, status: 200, value: ["received":true]); message = "\(received.count) files ready to import"
            default: respondJSON(id, status: 404, value: ["error":"Unknown transfer request"])
            }
        } catch { respondJSON(id, status: 400, value: ["error":error.localizedDescription]) }
    }
    private func respondUpload(_ id: UUID, _ upload: WiFiUploadStore.Upload) {
        respondJSON(id, status: 200, value: ["id":upload.id,"offset":upload.offset,"hashes":upload.hashes,"completed":upload.completed])
    }
    private func respondJSON(_ id: UUID, status: Int, value: [String: Any]) { respond(id, status: status, data: (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)) }
    private func respond(_ id: UUID, status: Int, data: Data, type: String = "application/json", extra: String = "") {
        guard let connection = peers[id]?.connection else { return }
        peers[id]?.processing = true
        let header = "HTTP/1.1 \(status) Response\r\nContent-Length: \(data.count)\r\nContent-Type: \(type)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; script-src 'self'; connect-src 'self'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'\r\n\(extra)\r\n"
        var response = Data(header.utf8); response.append(data)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in Task { @MainActor in self?.close(id) } })
    }
    private static func localPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            let bytes = Array(address.rawValue)
            return localIPv4(bytes)
        case .ipv6(let address):
            let bytes = Array(address.rawValue)
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 { return localIPv4(Array(bytes.suffix(4))) }
            return bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) || (bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1)
        default: return false
        }
    }
    private static func localIPv4(_ bytes: [UInt8]) -> Bool {
        bytes[0] == 10 || bytes[0] == 127 || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 169 && bytes[1] == 254)
    }
    private static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var current = list
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: item.pointee.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
        }
        return nil
    }
    private static let page = """
    <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>LocalTunes Transfer</title>
    <style>body{font:16px system-ui;max-width:640px;margin:10vh auto;padding:24px;background:#fff;color:#161618}h1{font-size:40px;letter-spacing:-1.5px}section{padding:24px;background:#f3f3f6;border-radius:18px;margin:24px 0}input{display:block;margin:16px 0;max-width:100%}progress{width:100%;height:16px;accent-color:#fa243c}button{background:#fa243c;color:white;border:0;border-radius:30px;padding:12px 24px;font:inherit}button:disabled{opacity:.5}p{line-height:1.6}small{color:#666}@media(prefers-color-scheme:dark){body{background:#000;color:#fff}section{background:#202023}small{color:#aaa}}</style>
    <h1>LocalTunes Transfer</h1><p>Send music from this PC to your iPhone.</p><section>
    <label>Choose music files<input id="files" type="file" multiple></label><label>Or choose a music folder<input id="folder" type="file" multiple webkitdirectory></label>
    <progress id="progress" value="0" max="1"></progress><p id="status" role="status">Keep the transfer screen open on the iPhone. Select the same files again to resume a paused upload.</p><button id="pause" disabled>Pause</button></section>
    <small>Files travel over your local network. Completed files wait in Import until you import them on the phone. Audio and LRC/TXT lyrics are supported, up to 20 GB per file.</small><script src="client.js"></script></html>
    """
}
