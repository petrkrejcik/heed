import Foundation

/// A sidebar row's state, rolled up from all of the task's tabs: the most urgent agent, and whether Kibana runs.
public struct TaskRollup: Hashable, Sendable {
    /// The most urgent agent tab's state; nil when the task has no agent tab.
    public var agent: ObservedState?
    /// That tab's activity.
    public var activity: String
    public var agentCount: Int
    public var kibanaRunning: Bool

    public init(agent: ObservedState?, activity: String = "", agentCount: Int = 0, kibanaRunning: Bool = false) {
        self.agent = agent
        self.activity = activity
        self.agentCount = agentCount
        self.kibanaRunning = kibanaRunning
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
        let panes = (layout?.tabs ?? []).flatMap(\.tree.panes).filter { $0.role == .agent }
        let tabs = panes.map { agents[$0.id] ?? AgentTab() }
        let top = tabs.enumerated().min {
            (urgency($0.element.state.state), $0.offset) < (urgency($1.element.state.state), $1.offset)
        }?.element
        return TaskRollup(
            agent: top?.state, activity: top?.activity ?? "", agentCount: tabs.count, kibanaRunning: task.running
        )
    }
}

/// The sidebar's groups, in order. A task sits in exactly one.
public enum TaskGroup: String, CaseIterable, Sendable {
    case pinned = "Pinned"
    case needsYou = "Needs you"
    case working = "Working"
    case idle = "Idle"
    /// The note says Blocked: waiting on something outside Heed.
    case blocked = "Blocked"

    public static let maxPins = 9

    /// Pinned, then an agent waiting on you, then the note's Blocked; then the agents decide, working or idle.
    public static func of(_ task: WorkTask, rollup: TaskRollup) -> TaskGroup {
        if task.pinned { return .pinned }
        if rollup.needsYou { return .needsYou }
        if task.status == .blocked { return .blocked }
        if let state = rollup.agent?.state, state == .working || state == .limited { return .working }
        return .idle
    }
}

/// The tasks as the sidebar lists them: In Progress and Blocked ones plus pinned ones, grouped, the most recently
/// active first in each group (pinned ones by title, so their `'1`..`'9` stay put), so `j`/`k` and counts walk the
/// list you see.
public struct TaskList: Sendable {
    public struct Section: Sendable {
        public let group: TaskGroup
        public let tasks: [WorkTask]
    }

    public let sections: [Section]
    /// Every listed task in display order.
    public let ordered: [WorkTask]
    public let rollups: [String: TaskRollup]

    public init(_ tasks: [WorkTask], layouts: [String: TaskLayout] = [:], agents: [String: AgentTab] = [:]) {
        let shown = tasks.filter { $0.pinned || $0.status.isActive }
        let pairs = shown.map { ($0.id, TaskRollup.of($0, layout: layouts[$0.id], agents: agents)) }
        let rollups = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        let grouped = Dictionary(grouping: shown) { TaskGroup.of($0, rollup: rollups[$0.id] ?? TaskRollup(agent: nil)) }
        sections = TaskGroup.allCases.compactMap { group in
            guard let members = grouped[group], !members.isEmpty else { return nil }
            let sorted = group == .pinned
                ? members.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                : members.sorted { ($0.lastActivity, $1.id) > ($1.lastActivity, $0.id) }
            return Section(group: group, tasks: sorted)
        }
        ordered = sections.flatMap(\.tasks)
        self.rollups = rollups
    }

    public func rollup(of id: String) -> TaskRollup { rollups[id] ?? TaskRollup(agent: nil) }

    /// The group a task is shown in.
    public func group(of id: String) -> TaskGroup? {
        sections.first { $0.tasks.contains { $0.id == id } }?.group
    }

    /// The pinned tasks in pin order, for `'1`..`'9`.
    public var pins: [WorkTask] { ordered.filter(\.pinned) }

    /// Vim-style relative numbers: the cursor row shows its absolute position (1-based), the others their distance.
    public func lineNumber(of index: Int, cursor: Int) -> Int {
        index == cursor ? index + 1 : abs(index - cursor)
    }

    /// The next task after `cursor` with an agent waiting on you (blocked or asking), wrapping around. For `ga`.
    public func nextNeedingYou(after cursor: Int) -> Int? {
        guard !ordered.isEmpty else { return nil }
        for step in 1 ... ordered.count {
            let index = (cursor + step) % ordered.count
            if rollup(of: ordered[index].id).needsYou { return index }
        }
        return nil
    }
}
