import Foundation

/// Keep cache warm, on a task's agent: shortly before its prompt cache expires Heed pings the agent's Claude session
/// (`ClaudePing`, a separate headless Claude), so the hour starts again, until the day's cut-off. Off when nil.
public struct KeepWarm: Hashable, Sendable, Codable {
    /// When it was turned on.
    public var since: Date
    /// The last ping that read the context from the cache; nil before the first.
    public var lastPing: Ping?

    public init(since: Date, lastPing: Ping? = nil) {
        self.since = since
        self.lastPing = lastPing
    }

    /// A ping that hit: when it started, what it read from and wrote to the cache, and what it cost.
    public struct Ping: Hashable, Sendable, Codable {
        public var at: Date
        public var read: Int
        public var written: Int
        public var cost: Double

        public init(at: Date, read: Int, written: Int, cost: Double) {
            self.at = at
            self.read = read
            self.written = written
            self.cost = cost
        }
    }

    /// The ping goes this long after the cache time.
    public static let pingAfter: TimeInterval = 55 * 60
    /// And never once the cache time is this old: it is the Stop hook's time, a little after the request that
    /// refreshed the cache, so later than this a ping could find the cache gone and rebuild it at full price.
    public static let latest: TimeInterval = 58 * 60
    /// A ping hits when at least this share of its context came from the cache.
    public static let hitShare = 0.8

    public enum Decision: Equatable, Sendable {
        case ping
        /// Nothing to do before then; check again.
        case wait(until: Date)
        /// The agent works or waits on you: its turn ends with a report, which checks again.
        case waitForTurn
        case stop(StopReason)
    }

    /// Why it turned off, or could not turn on.
    public enum StopReason: Equatable, Sendable {
        case noSession
        case noCache
        case expired
        case pastCutoff(ClockTime)
        case miss(read: Int, written: Int)
        case failed(String)

        public var text: String {
            switch self {
            case .noSession: "Heed does not know the agent's Claude session"
            case .noCache: "no prompt cache yet: it starts when the agent's turn ends"
            case .expired: "the prompt cache has expired; a ping would rebuild it at full price"
            case let .pastCutoff(time): "it is past \(time.text) ([keepwarm] until)"
            case let .miss(read, written): "the ping missed the cache (\(read) read, \(written) written)"
            case let .failed(why): "the ping failed: \(why)"
            }
        }
    }

    /// What to do for `agent` now, its keep-warm on. `until`: the cut-off, `[keepwarm] until`, today.
    public static func next(
        _ agent: AgentTab, now: Date, until: ClockTime, calendar: Calendar = .current
    ) -> Decision {
        guard agent.claudeSessionID != nil else { return .stop(.noSession) }
        guard let cache = PromptCache.turnEnded(agent) else { return .stop(.noCache) }
        let cutoff = until.date(on: now, calendar: calendar)
        guard now < cutoff else { return .stop(.pastCutoff(until)) }
        guard [.idle, .done, .exited].contains(agent.state.state) else { return .waitForTurn }
        let age = now.timeIntervalSince(cache)
        // Also a Mac that slept through the window: never a late ping.
        guard age < latest else { return .stop(.expired) }
        if age >= pingAfter { return .ping }
        return .wait(until: min(cache.addingTimeInterval(pingAfter), cutoff))
    }

    public static func isHit(read: Int, written: Int) -> Bool {
        read > 0 && Double(read) >= hitShare * Double(read + written)
    }
}

/// A time of day, as `[keepwarm] until` writes it: `17:00`.
public struct ClockTime: Hashable, Sendable, Codable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// `17:00`, `9:30`; nil for anything else.
    public init?(parsing text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0 ... 23).contains(hour), (0 ... 59).contains(minute)
        else { return nil }
        self.init(hour: hour, minute: minute)
    }

    public var text: String { String(format: "%d:%02d", hour, minute) }

    /// This time on `day`'s date.
    public func date(on day: Date, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }
}
