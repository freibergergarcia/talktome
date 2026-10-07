import Foundation

/// Daily counters for the stat cards. Counts only: no transcript text is
/// ever written to disk.
struct Stats: Codable {
    struct Day: Codable {
        var words = 0
        var dictations = 0
        var speakingSeconds = 0.0
    }

    /// Keyed by yyyy-MM-dd.
    var days: [String: Day] = [:]
    var lastLatencyMs: Int?

    /// Average typing speed used for "time saved".
    static let typingWordsPerMinute = 40.0

    var today: Day { days[Self.key(for: .now)] ?? Day() }

    /// Minutes saved today versus typing the same words.
    var minutesSavedToday: Double {
        max(0, Double(today.words) / Self.typingWordsPerMinute - today.speakingSeconds / 60)
    }

    /// Consecutive days, ending today or yesterday, with at least one dictation.
    var streak: Int {
        var count = 0
        var date = Date.now
        if days[Self.key(for: date)] == nil {
            date = Calendar.current.date(byAdding: .day, value: -1, to: date)!
        }
        while days[Self.key(for: date)] != nil {
            count += 1
            date = Calendar.current.date(byAdding: .day, value: -1, to: date)!
        }
        return count
    }

    mutating func record(text: String, seconds: Double, latencyMs: Int) {
        let words = text.split(whereSeparator: \.isWhitespace).count
        days[Self.key(for: .now), default: Day()].words += words
        days[Self.key(for: .now), default: Day()].dictations += 1
        days[Self.key(for: .now), default: Day()].speakingSeconds += seconds
        lastLatencyMs = latencyMs
    }

    private static func key(for date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }

    // MARK: - Persistence

    private static let defaultsKey = "stats"

    static func load() -> Stats {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let stats = try? JSONDecoder().decode(Stats.self, from: data) else { return Stats() }
        return stats
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
