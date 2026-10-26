import Foundation

/// A task's tabs and splits: restored on launch, so it is part of the domain rather than view state.
public struct TaskLayout: Hashable, Sendable, Codable {
    public var tabs: [PaneTab]
    public var activeTab: Int

    public init(tabs: [PaneTab], activeTab: Int = 0) {
        self.tabs = tabs
        self.activeTab = activeTab
    }

    public var panes: [PaneSpec] { tabs.flatMap(\.tree.panes) }

    /// Removes a pane from whichever tab has it; a tab left without panes goes too. False when no tab has it.
    @discardableResult
    public mutating func removePane(_ id: String) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.tree.panes.contains { $0.id == id } }) else { return false }
        var tab = tabs[index]
        let focused = tab.focused
        tab.focused = id
        if tab.closeFocused() {
            if focused != id, tab.tree.panes.contains(where: { $0.id == focused }) { tab.focused = focused }
            tabs[index] = tab
        } else {
            removeTab(at: index)
        }
        return true
    }

    /// Removes a tab, keeping the active one active (or its neighbour, when it was the one removed).
    public mutating func removeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        if index < activeTab { activeTab -= 1 }
        activeTab = max(0, min(activeTab, tabs.count - 1))
    }

    /// The first agent pane (its tab index and id), else the first pane: where prompts are typed.
    public var agentPane: (tab: Int, pane: String)? {
        for (index, tab) in tabs.enumerated() {
            if let pane = tab.tree.panes.first(where: { $0.role == .agent }) { return (index, pane.id) }
        }
        return tabs.first?.tree.panes.first.map { (0, $0.id) }
    }
}

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

    public init(
        tasks: [WorkTask] = [], layouts: [String: TaskLayout] = [:], agents: [String: AgentTab] = [:],
        github: GitHubState = GitHubState(), pullDetails: [String: PullDetail] = [:]
    ) {
        self.tasks = tasks
        self.layouts = layouts
        self.agents = agents
        self.github = github
        self.pullDetails = pullDetails
    }

    public static let empty = Domain()

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
    /// Agent tabs of panes the new layout no longer has go too.
    case layoutChanged(task: String, TaskLayout)
    case agentChanged(pane: String, AgentTab)
    /// A GitHub sync finished (or failed: the status says so and the data is the previous data).
    case githubSynced(GitHubState)
    /// Notification threads marked read.
    case inboxRead([String])
    /// A PR's detail arrived.
    case pullDetailFetched(PullDetail)
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
            let kept = Set(layout.panes.map(\.id))
            for pane in layouts[task]?.panes ?? [] where !kept.contains(pane.id) {
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
