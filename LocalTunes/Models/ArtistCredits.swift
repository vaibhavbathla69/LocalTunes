import Foundation

enum ArtistCredits {
    static func displayName(_ raw: String) -> String {
        let cleaned = raw.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "[\u{200B}\u{FEFF}\u{2060}\u{200E}\u{200F}]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }

    static func key(_ raw: String) -> String {
        displayName(raw).replacingOccurrences(of: "’", with: "'")
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func names(artist: String, title: String) -> [String] {
        let marker = #"(?i)(?:\s*[\(\[]\s*|\s+)(?:feat(?:uring)?\.?|ft\.?)\s+"#
        let marked = artist.replacingOccurrences(of: marker, with: "\u{001F}", options: .regularExpression)
        let parts = marked.components(separatedBy: "\u{001F}")
        var result = split(parts.first ?? artist, featured: false)
        for part in parts.dropFirst() { result += split(part, featured: true) }
        let titlePattern = #"(?i)[\(\[]\s*(?:feat(?:uring)?\.?|ft\.?)\s+([^\)\]]+)[\)\]]"#
        if let regex = try? NSRegularExpression(pattern: titlePattern) {
            let range = NSRange(title.startIndex..., in: title)
            for match in regex.matches(in: title, range: range) {
                if let credit = Range(match.range(at: 1), in: title) { result += split(String(title[credit]), featured: true) }
            }
        }
        var seen: Set<String> = []
        return result.map(displayName).filter { !$0.isEmpty && seen.insert(key($0)).inserted }
    }

    private static func split(_ raw: String, featured: Bool) -> [String] {
        let text = featured ? raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ")]"))) : raw
        // Explicit list separators are safe for main credits. Preserve AC/DC, Tyler, the Creator,
        // and band names containing '&' rather than guessing that punctuation is always a list.
        let pattern = featured ? #"\s*(?:;|\||\x00)\s*|\s+/\s+|\s+&\s+"# : #"\s*(?:;|\||\x00)\s*|\s+/\s+"#
        return text.replacingOccurrences(of: pattern, with: "\u{001F}", options: .regularExpression).components(separatedBy: "\u{001F}")
    }

    static func preferred(_ first: String, _ second: String) -> String {
        func score(_ name: String) -> Int {
            let lower = name.rangeOfCharacter(from: .lowercaseLetters) != nil
            let upper = name.rangeOfCharacter(from: .uppercaseLetters) != nil
            return lower && upper ? 2 : (lower ? 1 : 0)
        }
        return score(second) > score(first) ? second : first
    }
}
