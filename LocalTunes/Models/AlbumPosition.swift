import Foundation

enum AlbumPosition {
    /// Tags such as "03/12" and "2/2" describe track/disc number and total.
    static func number(_ text: String?) -> Int? {
        guard let value = text?.split(separator: "/").first?.trimmingCharacters(in: .whitespacesAndNewlines),
              let number = Int(value), (1...65535).contains(number) else { return nil }
        return number
    }

    static func mp4Number(_ data: Data?) -> Int? {
        guard let data, data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        let number = Int(bytes[2]) * 256 + Int(bytes[3])
        return number > 0 ? number : nil
    }

    /// Conservative filename fallback: 01 - Song, 2. Song, or disc-track 1-03 Song.
    static func filename(_ name: String) -> (disc: Int?, track: Int?) {
        let stem = (name as NSString).deletingPathExtension
        let regex = try! NSRegularExpression(pattern: #"^\s*(?:(\d{1,2})[-_.](\d{1,3})[\s._-]+|(\d{1,3})[\s._-]+)"#)
        let ns = stem as NSString
        guard let match = regex.firstMatch(in: stem, range: NSRange(location: 0, length: ns.length)) else { return (nil, nil) }
        func value(_ index: Int) -> Int? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : number(ns.substring(with: range))
        }
        return match.range(at: 1).location == NSNotFound ? (nil, value(3)) : (value(1), value(2))
    }
}
