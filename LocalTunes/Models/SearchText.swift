import Foundation

enum SearchText {
    static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func distance(_ left: String, _ right: String) -> Int {
        let a = Array(left.prefix(64)), b = Array(right.prefix(64))
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var row = [i + 1]
            for (j, y) in b.enumerated() { row.append(min(row[j] + 1, previous[j + 1] + 1, previous[j] + (x == y ? 0 : 1))) }
            previous = row
        }
        return previous[b.count]
    }
}
