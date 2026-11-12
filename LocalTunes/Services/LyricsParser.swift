import Foundation

struct LyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    let time: Double
    let text: String
}

struct ParsedLyrics: Sendable {
    var lines: [LyricLine]
    var plainText: String
    var isSynchronized: Bool { !lines.isEmpty }

    func activeIndex(at seconds: Double) -> Int? {
        guard seconds.isFinite, let first = lines.first, seconds >= first.time else { return nil }
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].time <= seconds { low = middle + 1 } else { high = middle }
        }
        return low - 1
    }
}

enum LyricsParser {
    static func parse(_ raw: String) -> ParsedLyrics {
        let raw = raw.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n")
        let pattern = #"\[(\d+):([0-5]?\d)(?:[\.:](\d{1,3}))?\]"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let offsetRegex = try! NSRegularExpression(pattern: #"\[offset:\s*([+-]?\d+)\]"#, options: .caseInsensitive)
        let nsRaw = raw as NSString
        var offset: Double = 0
        if let match = offsetRegex.firstMatch(in: raw, range: NSRange(location: 0, length: nsRaw.length)) {
            offset = (Double(nsRaw.substring(with: match.range(at: 1))) ?? 0) / 1000
        }
        var collected: [(time: Double, text: String, order: Int)] = []
        for row in raw.components(separatedBy: .newlines) {
            let ns = row as NSString
            let matches = regex.matches(in: row, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minute = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let second = Double(ns.substring(with: match.range(at: 2))) ?? 0
                let fractionRange = match.range(at: 3)
                let fraction = fractionRange.location == NSNotFound ? 0 : (Double("0." + ns.substring(with: fractionRange)) ?? 0)
                let time = minute * 60 + second + fraction + offset
                if time.isFinite { collected.append((max(0, time), text, collected.count)) }
            }
        }
        collected.sort { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
        // Co-timed translations appear together rather than immediately hiding one another.
        var merged: [(Double, String)] = []
        for value in collected {
            if let last = merged.last, abs(last.0 - value.time) < 0.0001 {
                merged[merged.count - 1].1 += "\n" + value.text
            } else { merged.append((value.time, value.text)) }
        }
        let lines = merged.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
        return ParsedLyrics(lines: lines, plainText: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func read(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 4_194_304 else { throw LibraryError.message("Lyrics file is too large (maximum 4 MB).") }
        let data = try Data(contentsOf: url)
        for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian] {
            if let value = String(data: data, encoding: encoding) { return value }
        }
        throw LibraryError.message("Could not read lyrics. Save the file as UTF-8 text or LRC.")
    }
}
