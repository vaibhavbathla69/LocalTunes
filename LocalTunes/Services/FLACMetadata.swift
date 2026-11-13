import Foundation

/// Reads only bounded FLAC metadata blocks, never the audio frames.
enum FLACMetadata {
    struct Tags: Sendable {
        var values: [String: String] = [:]
        var picture: Data?
        subscript(_ key: String) -> String? { values[key] }
        var year: Int? { values["DATE"].flatMap { Int($0.prefix(4)) } ?? values["YEAR"].flatMap(Int.init) }
    }
    static func read(_ url: URL) throws -> Tags? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data("fLaC".utf8) else { return nil }
        var tags = Tags(), total = 0
        for _ in 0..<1024 {
            try Task.checkCancellation()
            guard let header = try handle.read(upToCount: 4), header.count == 4 else { break }
            let type = header[0] & 0x7f
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            total += length
            guard total <= 64 * 1024 * 1024 else { break }
            if type == 4 || type == 6 {
                guard let block = try handle.read(upToCount: length), block.count == length else { break }
                if type == 4 { tags.values.merge(comments(block)) { first, _ in first } }
                else if tags.picture == nil { tags.picture = picture(block) }
            } else { try handle.seek(toOffset: handle.offsetInFile + UInt64(length)) }
            if header[0] & 0x80 != 0 { break }
        }
        return tags
    }
    static func comments(_ data: Data) -> [String: String] {
        var offset = 0
        func integer() -> Int? {
            guard offset + 4 <= data.count else { return nil }
            let value = (0..<4).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
            offset += 4; return value
        }
        func string(_ count: Int) -> String? {
            guard count <= data.count - offset else { return nil }
            defer { offset += count }
            return String(data: data.subdata(in: offset..<offset + count), encoding: .utf8)
        }
        guard let vendorLength = integer(), string(vendorLength) != nil, let count = integer(), count <= 100_000 else { return [:] }
        var result: [String: String] = [:]
        for _ in 0..<count {
            guard let size = integer(), let value = string(size), let equals = value.firstIndex(of: "=") else { break }
            let key = String(value[..<equals]).uppercased()
            if result[key] == nil { result[key] = String(value[value.index(after: equals)...]) }
        }
        return result
    }
    static func picture(_ data: Data) -> Data? {
        var offset = 0
        func integer() -> Int? {
            guard offset + 4 <= data.count else { return nil }
            let value = (0..<4).reduce(0) { ($0 << 8) | Int(data[offset + $1]) }
            offset += 4; return value
        }
        func skip(_ size: Int) -> Bool { guard size <= data.count - offset else { return false }; offset += size; return true }
        guard integer() != nil, let mime = integer(), skip(mime), let description = integer(), skip(description),
              skip(16), let length = integer(), length <= data.count - offset else { return nil }
        return data.subdata(in: offset..<offset + length)
    }
}
