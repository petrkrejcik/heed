import Foundation

/// A repository, always under an org or a personal account.
public struct Repo: Hashable, Sendable, Codable {
    public var org: String
    public var name: String

    public init(org: String, name: String) {
        self.org = org
        self.name = name
    }

    public var slug: String { "\(org)/\(name)" }
}

/// A pull request, identified across repos.
public struct PullRef: Hashable, Sendable, Codable, CustomStringConvertible {
    public var repo: Repo
    public var number: Int

    public init(repo: Repo, number: Int) {
        self.repo = repo
        self.number = number
    }

    /// `https://github.com/org/name/pull/123` (with or without a trailing path).
    public init?(url: String) {
        let parts = url.split(separator: "/").map(String.init)
        guard let pull = parts.firstIndex(of: "pull"), pull >= 2, pull + 1 < parts.count,
              let number = Int(parts[pull + 1].prefix { $0.isNumber })
        else { return nil }
        self.init(repo: Repo(org: parts[pull - 2], name: parts[pull - 1]), number: number)
    }

    public var description: String { "\(repo.slug)#\(number)" }
    public var url: String { "https://github.com/\(repo.slug)/pull/\(number)" }
}

/// A task note's `status`. pk knows six; anything else a note says is kept as written.
public struct TaskStatus: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let toDo = TaskStatus(rawValue: "To Do")
    public static let inProgress = TaskStatus(rawValue: "In Progress")
    public static let readyForReview = TaskStatus(rawValue: "Ready for Review")
    public static let blocked = TaskStatus(rawValue: "Blocked")
    public static let done = TaskStatus(rawValue: "Done")
    public static let dropped = TaskStatus(rawValue: "Dropped")

    public static let all: [TaskStatus] = [.toDo, .inProgress, .readyForReview, .blocked, .done, .dropped]

    /// Whether the sidebar lists a task with this status. Pinned tasks show whatever their status.
    public var isActive: Bool { self == .inProgress || self == .blocked }

    /// Done and Dropped end a task: setting one from Heed asks first and closes its terminals.
    public var endsTask: Bool { self == .done || self == .dropped }

    /// A status as typed after `:status`: the name in any case, or a short form (`todo`, `wip`, `review`, `drop`).
    public static func named(_ text: String) -> TaskStatus? {
        let key = text.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" }).joined(separator: " ")
        if let exact = all.first(where: { $0.rawValue.lowercased() == key }) { return exact }
        switch key {
        case "todo": return .toDo
        case "progress", "wip", "inprogress", "doing": return .inProgress
        case "review", "ready", "ready for review": return .readyForReview
        case "drop": return .dropped
        default: return nil
        }
    }

    public var description: String { rawValue }
}

/// One piece of work: one note in the vault, one Kanban card, one sidebar row. pk owns everything from `title` to
/// `created` (Heed only shows it); `lastActivity` and `timeline` are Heed's own.
public struct WorkTask: Identifiable, Hashable, Sendable, Codable {
    /// The note's `task_id`: stable across renames.
    public var id: String
    /// The note's file name.
    public var title: String
    public var status: TaskStatus
    public var pinned: Bool
    /// `review` for reviewing someone's PR; nil otherwise.
    public var kind: String?
    public var issue: String?
    public var pr: String?
    public var worktree: String?
    public var branch: String?
    public var notePath: String?
    /// The Kibana port from pk's ports file; nil until the first `pk kbn`.
    public var port: Int?
    /// Whether something listens on `port`.
    public var running: Bool
    /// pk's address for the task's Kibana (its Caddy host, else the port); nil until it has a port.
    public var kibanaURL: String?
    public var epic: String?
    /// `2026-10-21`, as the note has it.
    public var created: String?
    public var lastActivity: Date
    /// What happened, coarsely: started, resumed, ended. Capped.
    public var timeline: [TimelineEvent]

    public init(
        id: String = UUID().uuidString.lowercased(), title: String, status: TaskStatus = .inProgress,
        pinned: Bool = false, kind: String? = nil, issue: String? = nil, pr: String? = nil, worktree: String? = nil,
        branch: String? = nil, notePath: String? = nil, port: Int? = nil, running: Bool = false,
        kibanaURL: String? = nil, epic: String? = nil, created: String? = nil, lastActivity: Date = Date(),
        timeline: [TimelineEvent] = []
    ) {
        self.kibanaURL = kibanaURL
        self.id = id
        self.title = title
        self.status = status
        self.pinned = pinned
        self.kind = kind
        self.issue = issue
        self.pr = pr
        self.worktree = worktree
        self.branch = branch
        self.notePath = notePath
        self.port = port
        self.running = running
        self.epic = epic
        self.created = created
        self.lastActivity = lastActivity
        self.timeline = timeline
    }

    public var pull: PullRef? { pr.flatMap(PullRef.init(url:)) }
    public var issueRef: IssueRef? { issue.flatMap(IssueRef.init(url:)) }
    public var isReview: Bool { kind == "review" }

    /// Where its agents and shells run: its worktree, else the main checkout.
    public var directory: String { worktree ?? Kibana.mainCheckout }

    /// The worktree's folder name, the small text under the title; nil for a task in the main checkout.
    public var worktreeName: String? {
        guard let worktree, worktree != Kibana.mainCheckout else { return nil }
        return (worktree as NSString).lastPathComponent
    }

    public static let timelineLimit = 50

    public mutating func record(_ text: String, at date: Date = Date()) {
        timeline.append(TimelineEvent(at: date, text: text))
        if timeline.count > Self.timelineLimit { timeline.removeFirst(timeline.count - Self.timelineLimit) }
    }
}

public struct TimelineEvent: Hashable, Sendable, Codable {
    public var at: Date
    public var text: String

    public init(at: Date, text: String) {
        self.at = at
        self.text = text
    }
}

/// What one agent tab is doing, from its own hooks. Kept per pane, so a task with two agents shows both.
public struct AgentTab: Hashable, Sendable, Codable {
    public var state: ObservedState
    /// What it is up to, in a few words ("running tests", "wants to run yarn build").
    public var activity: String
    /// Claude's own session id: assigned at launch (`--session-id`), resumed with `--resume`.
    public var claudeSessionID: String?
    /// When its last turn ended (the idle or done hook): the prompt cache countdown starts there.
    public var lastTurnAt: Date?

    public init(
        state: ObservedState = ObservedState(.idle, source: .guessed), activity: String = "",
        claudeSessionID: String? = nil, lastTurnAt: Date? = nil
    ) {
        self.state = state
        self.activity = activity
        self.claudeSessionID = claudeSessionID
        self.lastTurnAt = lastTurnAt
    }
}
