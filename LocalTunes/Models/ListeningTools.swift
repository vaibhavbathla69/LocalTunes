import Foundation

struct PlaybackBookmark: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    var songID: String
    var title: String
    var seconds: Double
    var created = Date()
}

struct SmartMixRule: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    var name = ""
    var artist = ""
    var genre = ""
    var fromYear: Int? = nil
    var throughYear: Int? = nil
    var favouritesOnly = false
    var unplayedOnly = false
    var notPlayedDays: Int? = nil
    var limit = 50
    var shuffled = false
}

struct ListeningVisit: Identifiable, Sendable {
    var id: String
    var songID: String
    var title: String
    var artist: String
    var started: Date
    var ended: Date
    var seconds: Double
}

struct ListeningSession: Identifiable, Sendable {
    var id: String { visits.first?.id ?? "" }
    var visits: [ListeningVisit]
    var started: Date { visits.first!.started }
    var seconds: Double { visits.reduce(0) { $0 + $1.seconds } }
    static func group(_ visits: [ListeningVisit]) -> [ListeningSession] {
        var sessions: [ListeningSession] = []
        for visit in visits.sorted(by: { $0.started < $1.started }) {
            if let last = sessions.last?.visits.last, visit.started.timeIntervalSince(last.ended) < 1800 {
                sessions[sessions.count - 1].visits.append(visit)
            } else { sessions.append(ListeningSession(visits: [visit])) }
        }
        return sessions.reversed()
    }
}

enum LyricTiming {
    static func lrc(lines: [String], times: [Double], offset: Double = 0) -> String {
        zip(lines, times).map { text, time in
            let centiseconds = Int((max(0, time + offset) * 100).rounded())
            return String(format: "[%02d:%02d.%02d]", centiseconds / 6000, centiseconds / 100 % 60, centiseconds % 100) + text
        }.joined(separator: "\n")
    }
}
