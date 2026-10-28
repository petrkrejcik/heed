import Foundation

/// The small tags on a sidebar row's last line, in this order: Kibana running, the PR, the prompt cache countdown. A
/// task with none has no last line.
public enum TaskTag: Hashable, Sendable {
    case kibana(port: Int)
    case pull(PullTag)
    case cache(PromptCache.Countdown)

    /// `pull` is the task's PR as the sync and its details see it (nil when the task has none).
    public static func of(_ task: WorkTask, rollup: TaskRollup, pull: PullTag?, now: Date) -> [TaskTag] {
        var tags: [TaskTag] = []
        if rollup.kibanaRunning, let port = task.port { tags.append(.kibana(port: port)) }
        if let pull { tags.append(.pull(pull)) }
        if let cache = PromptCache.countdown(turns: rollup.cacheTurns, now: now) { tags.append(.cache(cache)) }
        return tags
    }
}

/// A task's PR on its sidebar row: the number, colored by where the PR is (draft, open, merged, closed), and the CI or
/// review mark before it only when there is something to act on.
public struct PullTag: Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        case draft, open, merged, closed
    }

    public let number: Int
    /// Nil until the sync or the PR's details arrive.
    public let state: State?
    /// Failing checks, a conflict (or behind), open threads or changes requested; nil for anything calmer, and for a
    /// merged or closed PR.
    public let alert: PullStatus?

    public init(number: Int, state: State?, alert: PullStatus? = nil) {
        self.number = number
        self.state = state
        self.alert = alert
    }

    /// From the sync's summary (`pull`) and the fetched details, the details first as `PullStatus` reads them.
    public static func of(_ ref: PullRef, pull: PullRequest?, detail: PullDetail?) -> PullTag {
        let state: State? = if pull?.state == .merged || detail?.state == "MERGED" {
            .merged
        } else if pull?.state == .closed || detail?.state == "CLOSED" {
            .closed
        } else if let draft = detail?.isDraft ?? pull?.isDraft {
            draft ? .draft : .open
        } else if pull != nil || detail?.state == "OPEN" {
            .open
        } else {
            nil
        }
        guard state == .open || state == .draft else { return PullTag(number: ref.number, state: state) }
        // A draft's status is `.draft` whatever its checks say; read it as if ready, so a failing draft still shows.
        var ready = detail
        ready?.isDraft = false
        let status = PullStatus.of(pull: pull, detail: ready)
        return PullTag(number: ref.number, state: state, alert: status.isAlert ? status : nil)
    }
}

public extension PullStatus {
    /// Something to act on: a failing check, a conflict, open threads or changes requested.
    var isAlert: Bool {
        switch self {
        case .failing, .conflicted, .changes: true
        case .pending, .draft, .green, .passing, .closed: false
        }
    }
}

/// Claude's prompt cache: it lasts an hour from the agent's last response, so a turn sent within that hour is cheap and
/// fast. Heed counts down from the end of the agent's last turn (`AgentTab.lastTurnAt`, from the Stop hook).
public enum PromptCache {
    public static let ttl: TimeInterval = 60 * 60
    /// At this many minutes left or fewer the countdown turns amber.
    public static let warningMinutes = 5

    public struct Countdown: Hashable, Sendable {
        /// The turn it counts from.
        public let turnEndedAt: Date
        /// Rounded up, so it says `1m` in the last minute and is gone once the cache expired.
        public let minutesLeft: Int

        public var expiresAt: Date { turnEndedAt.addingTimeInterval(PromptCache.ttl) }
        public var isWarning: Bool { minutesLeft <= PromptCache.warningMinutes }
    }

    /// Nil once the cache expired. A turn stamped a little in the future (the hook's clock) counts as just ended.
    public static func countdown(from turnEndedAt: Date, now: Date) -> Countdown? {
        let left = min(turnEndedAt.addingTimeInterval(ttl).timeIntervalSince(now), ttl)
        guard left > 0 else { return nil }
        return Countdown(turnEndedAt: turnEndedAt, minutesLeft: Int((left / 60).rounded(.up)))
    }

    /// Of several agents' turns, the cache that expires soonest and has not yet: the one to use before it is gone.
    public static func countdown(turns: [Date], now: Date) -> Countdown? {
        turns.compactMap { countdown(from: $0, now: now) }.min { $0.turnEndedAt < $1.turnEndedAt }
    }

    /// `lastTurnAt` after a state report. Only a turn that ended (Stop: done, no error) got a response from Claude.
    /// Idle
    /// is not a response: a resumed session (SessionStart `resume`) or the idle notice keep the last turn's time, and a
    /// new, cleared or compacted conversation (SessionStart `startup`, `clear`, `compact`) starts with no cache.
    public static func lastTurn(after state: AgentState, reason: String?, at: Date, previous: Date?) -> Date? {
        switch (state, reason) {
        case (.done, nil): at
        case (.idle, "startup"), (.idle, "clear"), (.idle, "compact"): nil
        default: previous
        }
    }

    /// When the agent's cache started counting: its last turn's end, in any state. While it works the countdown stays
    /// (a background agent's tools report working too, though the conversation's cache is not refreshed), and it
    /// starts again when the turn ends.
    public static func turnEnded(_ agent: AgentTab) -> Date? { agent.lastTurnAt }
}
