import Foundation

/// A sidebar row's state, rolled up from all of the task's tabs: the most urgent agent, whether Kibana runs, and when
/// the agents whose turn is over ended it.
public struct TaskRollup: Hashable, Sendable {
    /// The most urgent agent tab's state; nil when the task has no agent tab.
    public var agent: ObservedState?
    /// That tab's activity.
    public var activity: String
    public var agentCount: Int
    public var kibanaRunning: Bool
    /// Where the prompt cache countdowns start (`PromptCache.turnEnded`), one per agent tab that has one.
    public var cacheTurns: [Date]

    public init(
        agent: ObservedState?, activity: String = "", agentCount: Int = 0, kibanaRunning: Bool = false,
        cacheTurns: [Date] = []
    ) {
        self.agent = agent
        self.activity = activity
        self.agentCount = agentCount
        self.kibanaRunning = kibanaRunning
        self.cacheTurns = cacheTurns
    }

    public var needsYou: Bool { agent?.state.needsYou ?? false }

    /// Lower is more urgent: someone waiting on you, then work going on, then a finished turn, then quiet.
    public static func urgency(_ state: AgentState) -> Int {
        switch state {
        case .blocked: 0
        case .asking: 1
        case .working: 2
        case .limited: 3
        case .done: 4
        case .idle: 5
        case .exited: 6
        }
    }

    /// The task's agent tabs are the `.agent` panes of its layout; one with no report yet counts as idle, guessed.
    public static func of(_ task: WorkTask, layout: TaskLayout?, agents: [String: AgentTab]) -> TaskRollup {
        let panes = (layout?.panes ?? []).filter { $0.role == .agent }
        let tabs = panes.map { agents[$0.id] ?? AgentTab() }
        let top = tabs.enumerated().min {
            (urgency($0.element.state.state), $0.offset) < (urgency($1.element.state.state), $1.offset)
        }?.element
        return TaskRollup(
            agent: top?.state, activity: top?.activity ?? "", agentCount: tabs.count, kibanaRunning: task.running,
            cacheTurns: tabs.compactMap(PromptCache.turnEnded)
        )
    }
}

/// The sidebar's sections, in order: Pinned, then the Kanban's columns. A task sits in exactly one.
public enum TaskGroup: String, CaseIterable, Sendable, Codable {
    case pinned = "Pinned"
    case toDo = "To Do"
    case inProgress = "In Progress"
    case blocked = "Blocked"
    case readyForReview = "Ready for Review"
    case done = "Done"
    case dropped = "Dropped"
    /// A status pk does not know, as the note wrote it: listed rather than lost.
    case other = "Other"

    public static let maxPins = 9

    /// What a sidebar shows closed until you open it: the work not started and the work finished.
    public static let collapsedByDefault: Set<TaskGroup> = [.toDo, .done, .dropped]

    /// A pinned task sits under Pinned whatever its status (so `'1`..`'9` stay put); the others under their status.
    public static func of(_ task: WorkTask) -> TaskGroup {
        task.pinned ? .pinned : TaskGroup(status: task.status)
    }

    public init(status: TaskStatus) {
        self = switch status {
        case .toDo: .toDo
        case .inProgress: .inProgress
        case .blocked: .blocked
        case .readyForReview: .readyForReview
        case .done: .done
        case .dropped: .dropped
        default: .other
        }
    }

    /// A section as typed after `:section`: `pinned`, `other`, or a status as `:status` takes it (`todo`, `review`).
    public static func named(_ text: String) -> TaskGroup? {
        let key = text.trimmingCharacters(in: .whitespaces).lowercased()
        if ["pinned", "pins", "pin"].contains(key) { return .pinned }
        if key == "other" { return .other }
        return TaskStatus.named(key).map(TaskGroup.init(status:))
    }
}

/// The tasks as the sidebar lists them: every task, in a section per status (pinned ones under Pinned, by title, so
/// their `'1`..`'9` stay put; the others most recently active first). A collapsed section shows its header and count
/// only: its rows are not in `ordered`, so `j`/`k`, `gg`/`G`, `{`/`}`, counts and line numbers walk the rows you see.
public struct TaskList: Sendable {
    public struct Section: Sendable {
        public let group: TaskGroup
        public let tasks: [WorkTask]
        public let collapsed: Bool
    }

    /// The sections that have tasks, open or collapsed.
    public let sections: [Section]
    /// The rows of the open sections in display order: what the cursor indexes.
    public let ordered: [WorkTask]
    /// Every listed task in display order, collapsed sections' too.
    public let all: [WorkTask]
    public let rollups: [String: TaskRollup]

    public init(
        _ tasks: [WorkTask], layouts: [String: TaskLayout] = [:], agents: [String: AgentTab] = [:],
        collapsed: Set<TaskGroup> = TaskGroup.collapsedByDefault
    ) {
        let pairs = tasks.map { ($0.id, TaskRollup.of($0, layout: layouts[$0.id], agents: agents)) }
        rollups = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        let grouped = Dictionary(grouping: tasks, by: TaskGroup.of)
        sections = TaskGroup.allCases.compactMap { group in
            guard let members = grouped[group], !members.isEmpty else { return nil }
            let sorted = group == .pinned
                ? members.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                : members.sorted { ($0.lastActivity, $1.id) > ($1.lastActivity, $0.id) }
            return Section(group: group, tasks: sorted, collapsed: collapsed.contains(group))
        }
        all = sections.flatMap(\.tasks)
        ordered = sections.filter { !$0.collapsed }.flatMap(\.tasks)
    }

    public func rollup(of id: String) -> TaskRollup { rollups[id] ?? TaskRollup(agent: nil) }

    /// The section a task is listed in.
    public func group(of id: String) -> TaskGroup? {
        sections.first { $0.tasks.contains { $0.id == id } }?.group
    }

    /// Whether the task is listed in a collapsed section.
    public func isHidden(_ id: String) -> Bool {
        sections.first { $0.tasks.contains { $0.id == id } }?.collapsed ?? false
    }

    /// The task's row, nil when it is not one (collapsed, or not listed).
    public func index(of id: String) -> Int? { ordered.firstIndex { $0.id == id } }

    /// The pinned tasks in pin order, for `'1`..`'9`.
    public var pins: [WorkTask] { all.filter(\.pinned) }

    /// The listed tasks that have not ended (Done, Dropped), plus pinned ones: whose Kibana port and PR Heed keeps
    /// checking.
    public var live: [WorkTask] { all.filter { $0.pinned || !$0.status.endsTask } }

    /// Vim-style relative numbers: the cursor row shows its absolute position (1-based), the others their distance.
    public func lineNumber(of index: Int, cursor: Int) -> Int {
        index == cursor ? index + 1 : abs(index - cursor)
    }

    /// The next task after `id` with an agent waiting on you (blocked or asking), wrapping around, collapsed sections
    /// included. For `ga`.
    public func nextNeedingYou(after id: String?) -> WorkTask? {
        guard !all.isEmpty else { return nil }
        let start = id.flatMap { id in all.firstIndex { $0.id == id } } ?? -1
        for step in 1 ... all.count {
            let task = all[(start + step + all.count) % all.count]
            if rollup(of: task.id).needsYou { return task }
        }
        return nil
    }

    /// Where the cursor goes in this list, which replaced `before` (the old rows): on its task `id` when that is a
    /// row. When it is not (its section collapsed, or it moved into a collapsed one, or it went), the first row that
    /// was below it and still is, else the nearest one above; failing those, `cursor` kept in range.
    public func row(for id: String?, before: [WorkTask], cursor: Int) -> Int {
        guard !ordered.isEmpty else { return 0 }
        if let id, let index = index(of: id) { return index }
        if let id, let old = before.firstIndex(where: { $0.id == id }) {
            let rows = Dictionary(ordered.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            if let below = before[(old + 1)...].lazy.compactMap({ rows[$0.id] }).first { return below }
            if let above = before[..<old].reversed().lazy.compactMap({ rows[$0.id] }).first { return above }
        }
        return min(max(cursor, 0), ordered.count - 1)
    }
}

public extension Domain {
    /// The task you are on (`id`) moved into a collapsed section and still has tabs: the change that opens that
    /// section, so its agent stays in front of you instead of vanishing with the rows. A task without tabs leaves the
    /// section as it is and the cursor moves on (`TaskList.row(for:before:cursor:)`). Nil when nothing opens.
    func opening(sectionOf id: String?, movedFrom before: Domain) -> DomainChange? {
        guard let id, let now = task(id), let was = before.task(id) else { return nil }
        let group = TaskGroup.of(now)
        guard group != TaskGroup.of(was), collapsed.contains(group), layouts[id].map({ !$0.isEmpty }) == true
        else { return nil }
        return .collapsedChanged(collapsed.subtracting([group]))
    }
}
