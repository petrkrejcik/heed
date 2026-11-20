import Foundation

/// Everything Heed knows, as one value. The window is drawn from this (plus input state), it is what the cache
/// stores, and fixtures are just instances of it, so the UI can start in any state without IO. A cache with fields this
/// build no longer has still loads: decoding skips unknown keys.
///
/// Tasks are pk's (the notes are the database); Heed keeps them here only as a cache for a fast start. Layouts and
/// agent tabs are Heed's own.
public struct Domain: Hashable, Sendable, Codable {
    public var tasks: [WorkTask]
    public var layouts: [String: TaskLayout]
    /// Agent tabs by pane id.
    public var agents: [String: AgentTab]
    public var github: GitHubState
    /// PR details by `org/name#n`, for the reader (cached, so it opens offline).
    public var pullDetails: [String: PullDetail]
    /// The sidebar sections shown closed. UI state, so it lives here and never in the notes.
    public var collapsed: Set<TaskGroup>
    /// The vault's tag colours (its Tag Colors plugin), cached so the tags draw in colour at launch.
    public var tagColors: TagColors

    public init(
        tasks: [WorkTask] = [], layouts: [String: TaskLayout] = [:], agents: [String: AgentTab] = [:],
        github: GitHubState = GitHubState(), pullDetails: [String: PullDetail] = [:],
        collapsed: Set<TaskGroup> = TaskGroup.collapsedByDefault, tagColors: TagColors = .none
    ) {
        self.tasks = tasks
        self.layouts = layouts
        self.agents = agents
        self.github = github
        self.pullDetails = pullDetails
        self.collapsed = collapsed
        self.tagColors = tagColors
    }

    public static let empty = Domain()

    enum CodingKeys: String, CodingKey {
        case tasks, layouts, agents, github, pullDetails, collapsed, tagColors
    }

    /// A cache from before sections collapsed loads with the defaults; a section name this build does not know is
    /// skipped, so neither throws the cache away. One from before tag colours has none until the vault is read.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decode([WorkTask].self, forKey: .tasks)
        layouts = try container.decode([String: TaskLayout].self, forKey: .layouts)
        agents = try container.decode([String: AgentTab].self, forKey: .agents)
        github = try container.decode(GitHubState.self, forKey: .github)
        pullDetails = try container.decode([String: PullDetail].self, forKey: .pullDetails)
        collapsed = try container.decodeIfPresent([String].self, forKey: .collapsed)
            .map { Set($0.compactMap(TaskGroup.init(rawValue:))) } ?? TaskGroup.collapsedByDefault
        tagColors = try container.decodeIfPresent(TagColors.self, forKey: .tagColors) ?? .none
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tasks, forKey: .tasks)
        try container.encode(layouts, forKey: .layouts)
        try container.encode(agents, forKey: .agents)
        try container.encode(github, forKey: .github)
        try container.encode(pullDetails, forKey: .pullDetails)
        try container.encode(collapsed.map(\.rawValue).sorted(), forKey: .collapsed)
        try container.encode(tagColors, forKey: .tagColors)
    }

    public func task(_ id: String) -> WorkTask? { tasks.first { $0.id == id } }

    /// The task whose layout has pane `id`.
    public func task(ofPane id: String) -> String? {
        layouts.first { $0.value.panes.contains { $0.id == id } }?.key
    }
}

/// One edit to the domain. Adapters (pk, gh, hooks) and the UI both speak in these, so every change takes the same
/// path: applied to the store (and persisted), and applied to the main-actor model, which redraws only what changed.
public enum DomainChange: Hashable, Sendable, Codable {
    case taskUpserted(WorkTask)
    /// The task goes with its layout and its agent tabs.
    case taskRemoved(String)
    /// Agent tabs of panes the new layout no longer has go too; the layout keeps a closed agent's Claude session.
    case layoutChanged(task: String, TaskLayout)
    case agentChanged(pane: String, AgentTab)
    /// A GitHub sync finished (or failed: the status says so and the data is the previous data).
    case githubSynced(GitHubState)
    /// Notification threads marked read.
    case inboxRead([String])
    /// A PR's detail arrived.
    case pullDetailFetched(PullDetail)
    /// The sidebar sections shown closed, all of them.
    case collapsedChanged(Set<TaskGroup>)
    /// The vault's tag colours were read.
    case tagColorsRead(TagColors)
}

public extension Domain {
    mutating func apply(_ change: DomainChange) {
        switch change {
        case let .taskUpserted(task):
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = task
            } else {
                tasks.append(task)
            }
        case let .taskRemoved(id):
            tasks.removeAll { $0.id == id }
            for pane in layouts[id]?.panes ?? [] {
                agents[pane.id] = nil
            }
            layouts[id] = nil
        case let .layoutChanged(task, layout):
            var layout = layout
            let kept = Set(layout.panes.map(\.id))
            for pane in layouts[task]?.panes ?? [] where !kept.contains(pane.id) {
                if pane.role == .agent, let agent = agents[pane.id], let id = agent.claudeSessionID {
                    layout.closedAgent = ClosedAgent(
                        claudeSessionID: id, directory: pane.directory, lastTurnAt: agent.lastTurnAt
                    )
                }
                agents[pane.id] = nil
            }
            layouts[task] = layout
        case let .agentChanged(pane, tab):
            agents[pane] = tab
        case let .githubSynced(state):
            github = state
        case let .pullDetailFetched(detail):
            pullDetails[detail.ref.description] = detail
        case let .inboxRead(ids):
            for index in github.inbox.indices where ids.contains(github.inbox[index].id) {
                github.inbox[index].unread = false
            }
        case let .collapsedChanged(groups):
            collapsed = groups
        case let .tagColorsRead(colors):
            tagColors = colors
        }
    }

    func applying(_ changes: [DomainChange]) -> Domain {
        var copy = self
        for change in changes {
            copy.apply(change)
        }
        return copy
    }
}
