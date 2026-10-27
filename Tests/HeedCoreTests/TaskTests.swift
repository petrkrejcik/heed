import Foundation
@testable import HeedCore
import Testing

private func pane(_ id: String) -> PaneSpec { PaneSpec(id: id, role: .shell, title: id, directory: "/") }

private func task(
    _ id: String, status: TaskStatus = .inProgress, pinned: Bool = false, running: Bool = false, ago: Double = 0
) -> WorkTask {
    WorkTask(
        id: id, title: id, status: status, pinned: pinned, running: running,
        lastActivity: Date(timeIntervalSince1970: 1_000_000 - ago)
    )
}

/// A layout with one agent tab per id in `agents` (pane ids `<task>-<agent>`), plus a shell tab.
private func layout(_ task: String, agents: [String]) -> TaskLayout {
    let tabs = agents.map { agent in
        PaneTab(title: agent, tree: .leaf(PaneSpec(
            id: "\(task)-\(agent)", role: .agent, title: "claude", directory: "/"
        )))
    }
    return TaskLayout(tabs: tabs + [PaneTab(title: "shell", tree: .leaf(pane("\(task)-shell")))])
}

private func agent(_ state: AgentState, _ activity: String = "") -> AgentTab {
    AgentTab(state: ObservedState(state), activity: activity)
}

struct PaneTreeTests {
    @Test func splitsAndReadingOrder() {
        var tab = PaneTab(title: "t", tree: .leaf(pane("a")))
        tab.split(.horizontal, with: pane("b"))
        tab.focused = "a"
        tab.split(.vertical, with: pane("c"))
        #expect(tab.tree.panes.map(\.id) == ["a", "c", "b"])
        #expect(tab.focused == "c")
    }

    @Test func focusMovesAcrossSplits() {
        var tab = PaneTab(title: "t", tree: .leaf(pane("a")))
        tab.split(.horizontal, with: pane("b"))
        tab.focused = "a"
        tab.split(.vertical, with: pane("c"))
        tab.focus(.right)
        #expect(tab.focused == "b")
        tab.focus(.left)
        #expect(tab.focused == "c")
        tab.focus(.up)
        #expect(tab.focused == "a")
        tab.focus(.up)
        #expect(tab.focused == "a")
    }

    @Test func closingCollapsesToTheSibling() {
        var tab = PaneTab(title: "t", tree: .leaf(pane("a")))
        tab.split(.horizontal, with: pane("b"))
        let closed = tab.closeFocused()
        #expect(closed)
        #expect(tab.tree == .leaf(pane("a")))
        #expect(tab.focused == "a")
        let closedLast = tab.closeFocused()
        #expect(!closedLast)
    }
}

struct TaskLayoutTests {
    @Test func removingAPaneFromAnyTab() {
        let agent = PaneSpec(role: .agent, title: "claude", directory: "/w")
        let shell = PaneSpec(role: .shell, title: "zsh", directory: "/w")
        let tests = PaneSpec(role: .command, title: "jest", directory: "/w")
        var first = PaneTab(title: "agent", tree: .leaf(agent))
        first.split(.horizontal, with: shell)
        var layout = TaskLayout(tabs: [first, PaneTab(title: "jest", tree: .leaf(tests))], activeTab: 1)
        // A pane in a tab that is not active, and not focused there: the focus stays where it was.
        let focused = layout.tabs[0].focused
        let other = layout.removePane(focused == shell.id ? agent.id : shell.id)
        #expect(other)
        #expect(layout.tabs[0].tree.panes.count == 1)
        #expect(layout.activeTab == 1)
        // The last pane of a tab takes the tab with it; the active tab stays the one you were on.
        let last = layout.removePane(layout.tabs[0].tree.panes[0].id)
        #expect(last)
        #expect(layout.tabs.map(\.title) == ["jest"])
        #expect(layout.activeTab == 0)
        let missing = layout.removePane("nope")
        #expect(!missing)
        let final = layout.removePane(tests.id)
        #expect(final)
        #expect(layout.tabs.isEmpty)
    }

    @Test func removingATabKeepsTheActiveOne() {
        let tabs = ["a", "b", "c"].map { PaneTab(title: $0, tree: .leaf(pane($0))) }
        var layout = TaskLayout(tabs: tabs, activeTab: 2)
        layout.removeTab(at: 0)
        #expect(layout.tabs[layout.activeTab].title == "c")
        layout.removeTab(at: layout.activeTab)
        #expect(layout.tabs[layout.activeTab].title == "b")
    }

    @Test func promptsGoToTheFirstAgentPane() {
        let tabs = [PaneTab(title: "shell", tree: .leaf(pane("s")))] + layout("t", agents: ["a"]).tabs
        #expect(TaskLayout(tabs: tabs).agentPane?.pane == "t-a")
        #expect(TaskLayout(tabs: tabs).agentPane?.tab == 1)
        // No agent: the first pane.
        #expect(TaskLayout(tabs: [PaneTab(title: "s", tree: .leaf(pane("s")))]).agentPane?.pane == "s")
        #expect(TaskLayout(tabs: []).agentPane == nil)
    }
}

struct TaskListTests {
    @Test func theMostUrgentAgentTabSpeaksForTheTask() {
        let agents = ["t-a": agent(.working, "running jest"), "t-b": agent(.asking, "2 questions")]
        let rollup = TaskRollup.of(task("t", running: true), layout: layout("t", agents: ["a", "b"]), agents: agents)
        #expect(rollup.agent?.state == .asking)
        #expect(rollup.activity == "2 questions")
        #expect(rollup.agentCount == 2)
        #expect(rollup.kibanaRunning)
        #expect(rollup.needsYou)
        // An agent tab with no report yet counts as idle; a task without agent tabs has no state.
        let quiet = TaskRollup.of(task("t"), layout: layout("t", agents: ["a"]), agents: [:])
        #expect(quiet.agent?.state == .idle)
        #expect(quiet.agent?.source == .guessed)
        #expect(TaskRollup.of(task("t"), layout: nil, agents: [:]).agent == nil)
    }

    @Test func groupsInOrder() {
        let tasks = [
            task("idle"), task("busy"), task("pin", pinned: true), task("ask"), task("stuck", status: .blocked),
            task("done", status: .done), task("todo", status: .toDo), task("old pin", status: .done, pinned: true),
        ]
        let layouts = Dictionary(uniqueKeysWithValues: ["busy", "ask", "stuck"].map { ($0, layout($0, agents: ["a"])) })
        let agents = ["busy-a": agent(.working), "ask-a": agent(.asking), "stuck-a": agent(.working)]
        let list = TaskList(tasks, layouts: layouts, agents: agents)
        #expect(list.sections.map(\.group) == [.pinned, .needsYou, .working, .idle, .blocked])
        // Pinned ones by title; Done and To Do are not listed unless pinned.
        #expect(list.ordered.map(\.id) == ["old pin", "pin", "ask", "busy", "idle", "stuck"])
        #expect(list.group(of: "stuck") == .blocked)
        #expect(list.group(of: "done") == nil)
        #expect(list.pins.map(\.id) == ["old pin", "pin"])
    }

    @Test func anAgentWaitingOnYouBeatsTheNotesBlocked() {
        let list = TaskList(
            [task("t", status: .blocked)], layouts: ["t": layout("t", agents: ["a"])], agents: ["t-a": agent(.asking)]
        )
        #expect(list.group(of: "t") == .needsYou)
    }

    @Test func mostRecentlyActiveFirstInAGroup() {
        let list = TaskList([task("old", ago: 100), task("new", ago: 1), task("mid", ago: 50)])
        #expect(list.ordered.map(\.id) == ["new", "mid", "old"])
    }

    @Test func relativeLineNumbers() {
        let list = TaskList((0 ..< 5).map { task("t\($0)", ago: Double($0)) })
        #expect((0 ..< 5).map { list.lineNumber(of: $0, cursor: 2) } == [2, 1, 3, 1, 2])
    }

    @Test func nextNeedingYouWraps() {
        let ids = ["a", "b", "c", "d"]
        let layouts = Dictionary(uniqueKeysWithValues: ids.map { ($0, layout($0, agents: ["x"])) })
        let agents = ["a-x": agent(.working), "b-x": agent(.blocked), "c-x": agent(.working), "d-x": agent(.asking)]
        let list = TaskList(ids.enumerated().map { task($1, ago: Double($0)) }, layouts: layouts, agents: agents)
        // Ordered: needs-you first (b, d), then working (a, c).
        #expect(list.ordered.map(\.id) == ["b", "d", "a", "c"])
        #expect(list.nextNeedingYou(after: 0) == 1)
        #expect(list.nextNeedingYou(after: 1) == 0)
        #expect(TaskList([task("a")]).nextNeedingYou(after: 0) == nil)
    }

    @Test func aTaskWithoutAWorktreeRunsInTheMainCheckout() {
        var task = task("t")
        #expect(task.directory == Kibana.mainCheckout)
        #expect(task.worktreeName == nil)
        task.worktree = "/Users/you/www/kibana.worktrees/299433-fix-image-upload-403"
        #expect(task.worktreeName == "299433-fix-image-upload-403")
        task.pr = "https://github.com/elastic/kibana/pull/299455"
        task.issue = "https://github.com/elastic/kibana/issues/299433"
        #expect(task.pull == PullRef(repo: Kibana.repo, number: 299_455))
        #expect(task.issueRef == IssueRef(repo: Kibana.repo, number: 299_433))
    }

    @Test func theFixtureListsWhatThePlanSays() {
        let domain = Fixtures.tasks
        let list = TaskList(domain.tasks, layouts: domain.layouts, agents: domain.agents)
        #expect(list.ordered.first?.title == "Kibana main")
        #expect(list.group(of: "t1") == .pinned)
        #expect(list.group(of: "t2") == .working)
        #expect(list.rollup(of: "t2").agentCount == 2)
        #expect(list.rollup(of: "t2").kibanaRunning)
        #expect(list.group(of: "t4") == .blocked)
        #expect(list.group(of: "t6") == nil)
        #expect(list.group(of: "t7") == nil)
    }

    @Test func hintLabelsNeverPrefixEachOther() {
        #expect(HintLabels.generate(count: 3) == ["a", "s", "d"])
        let many = HintLabels.generate(count: 40)
        #expect(many.count == 40)
        #expect(Set(many.map(\.count)) == [2])
    }

    @Test func aliases() {
        #expect(CommandAliases.resolve("pr 2841") == CommandInvocation(name: "open.reader", arguments: ["pr", "2841"]))
        #expect(CommandAliases.resolve("inbox") == CommandInvocation(name: "view", arguments: ["inbox"]))
        #expect(CommandAliases.resolve("tasks") == CommandInvocation(name: "view", arguments: ["tasks"]))
        #expect(CommandAliases.resolve("new") == CommandInvocation(name: "task.new"))
        #expect(CommandAliases.resolve("pane.zoom") == CommandInvocation(name: "pane.zoom"))
    }
}

struct TaskDomainTests {
    @Test func aNewLayoutDropsTheAgentTabsOfPanesItNoLongerHas() {
        var domain = Domain(
            tasks: [task("t")], layouts: ["t": layout("t", agents: ["a", "b"])],
            agents: ["t-a": agent(.working), "t-b": agent(.idle), "other": agent(.idle)]
        )
        domain.apply(.layoutChanged(task: "t", layout("t", agents: ["a"])))
        #expect(Set(domain.agents.keys) == ["t-a", "other"])
        #expect(domain.task(ofPane: "t-a") == "t")
        #expect(domain.task(ofPane: "t-b") == nil)
    }

    @Test func removingATaskTakesItsLayoutAndAgentTabs() {
        var domain = Domain(
            tasks: [task("t"), task("u")], layouts: ["t": layout("t", agents: ["a"])],
            agents: ["t-a": agent(.working), "u-a": agent(.idle)]
        )
        domain.apply(.taskRemoved("t"))
        #expect(domain.tasks.map(\.id) == ["u"])
        #expect(domain.layouts.isEmpty)
        #expect(Array(domain.agents.keys) == ["u-a"])
    }

    @Test func upsertingReplacesByID() {
        var domain = Domain(tasks: [task("t")])
        var renamed = task("t")
        renamed.title = "Renamed"
        domain.apply(.taskUpserted(renamed))
        domain.apply(.taskUpserted(task("u")))
        #expect(domain.tasks.map(\.title) == ["Renamed", "u"])
    }

    @Test func theTimelineIsCapped() {
        var task = task("t")
        for index in 0 ..< WorkTask.timelineLimit + 5 {
            task.record("event \(index)")
        }
        #expect(task.timeline.count == WorkTask.timelineLimit)
        #expect(task.timeline.first?.text == "event 5")
    }
}

struct NewTaskTests {
    private func type(_ text: String, into form: inout NewTaskForm) {
        for character in text {
            _ = form.handle(character == " " ? KeyStroke("Space") : KeyStroke(String(character)))
        }
    }

    @Test func theDialogTakesOnlyATitle() {
        var form = NewTaskForm()
        type("Fix image upload", into: &form)
        #expect(form.title == "Fix image upload")
        _ = form.handle(KeyStroke("w", .control))
        #expect(form.title == "Fix image ")
        _ = form.handle(KeyStroke("BS"))
        form.paste("403\nbehind a proxy")
        #expect(form.title == "Fix image403 behind a proxy")
        _ = form.handle(KeyStroke("u", .control))
        #expect(form.title.isEmpty)
        // Other chords do nothing.
        #expect(form.handle(KeyStroke("k", .command)) == .ignored)
    }

    @Test func anEmptyTitleIsNotCreated() {
        var form = NewTaskForm()
        type("  ", into: &form)
        #expect(form.handle(KeyStroke("CR")) == .handled)
        #expect(form.error == "type a title first")
        type("x", into: &form)
        #expect(form.error == nil)
        #expect(form.handle(KeyStroke("CR")) == .create(title: "x", context: ""))
        var cancelled = NewTaskForm(title: "From GitHub", context: "prompt")
        #expect(cancelled.handle(.escape) == .cancel)
        var picked = NewTaskForm(title: "From GitHub", context: "Read #299433")
        #expect(picked.handle(KeyStroke("CR", .command)) == .create(title: "From GitHub", context: "Read #299433"))
    }

    @Test func startingATaskOpensClaudeInTheMainCheckoutWithItsOwnSessionID() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let changes = NewTask.start(
            WorkTask(id: "pk-1", title: "Fix image upload 403"), context: "Read the issue.", settings: .default,
            integration: nil, now: now
        )
        let domain = Domain.empty.applying(changes)
        let task = try #require(domain.tasks.first)
        #expect(task.id == "pk-1")
        #expect(task.title == "Fix image upload 403")
        #expect(task.status == .inProgress)
        #expect(task.worktree == nil)
        #expect(task.lastActivity == now)
        #expect(task.timeline.last?.text.hasPrefix("started · claude in ") == true)
        let layout = try #require(domain.layouts[task.id])
        #expect(layout.tabs.count == 1)
        let agentPane = try #require(layout.panes.first)
        #expect(agentPane.role == .agent)
        #expect(agentPane.directory == Kibana.mainCheckout)
        let tab = try #require(domain.agents[agentPane.id])
        let sessionID = try #require(tab.claudeSessionID)
        #expect(agentPane.command == "claude --session-id \(sessionID) 'Read the issue.'")
        #expect(tab.state.state == .idle)
    }

    @Test func aShellSplitSitsBesideTheAgent() {
        var settings = WorkSettings.default
        settings.shellSplit = true
        let domain = Domain.empty.applying(NewTask.start(WorkTask(title: "t"), settings: settings, integration: nil))
        let panes = domain.layouts.values.first?.panes ?? []
        #expect(panes.map(\.role) == [.agent, .shell])
        #expect(domain.layouts.values.first?.tabs.first?.focused == panes.first?.id)
    }

    @Test func theAgentKeyGoesToTheAgentTabTheTaskHas() {
        var layout = layout("t", agents: ["a"])
        layout.tabs.insert(PaneTab(title: "shell", tree: .leaf(pane("t-first"))), at: 0)
        let opening = NewTask.openAgent(
            in: layout, task: task("t"), agent: WorkSettings.default.claude, integration: nil
        )
        #expect(opening == .existing(tab: 1, pane: "t-a"))
    }

    @Test func aClosedAgentComesBackResumedWhereItWorked() throws {
        var domain = Domain(
            tasks: [task("t")], layouts: ["t": layout("t", agents: ["a"])],
            agents: ["t-a": AgentTab(claudeSessionID: "s-1")]
        )
        var moved = try #require(domain.layouts["t"])
        moved.tabs[0].tree = moved.tabs[0].tree.updating("t-a") { $0.directory = "/wt/fix" }
        domain.apply(.layoutChanged(task: "t", moved))
        var closed = try #require(domain.layouts["t"])
        closed.removeTab(at: 0)
        domain.apply(.layoutChanged(task: "t", closed))
        let kept = try #require(domain.layouts["t"])
        #expect(kept.closedAgent == ClosedAgent(claudeSessionID: "s-1", directory: "/wt/fix"))

        let opening = NewTask.openAgent(
            in: kept, task: task("t"), agent: WorkSettings.default.claude, integration: nil
        ) { id, directory in id == "s-1" && directory == "/wt/fix" }
        guard case let .opened(layout, paneID, agent, resumed) = opening else {
            Issue.record("expected a new agent tab, got \(String(describing: opening))")
            return
        }
        #expect(resumed)
        #expect(layout.closedAgent == nil)
        #expect(layout.activeTab == layout.tabs.count - 1)
        let pane = try #require(layout.tabs.last?.tree.panes.first)
        #expect(pane.id == paneID)
        #expect(pane.role == .agent)
        #expect(pane.directory == "/wt/fix")
        #expect(pane.command == "claude --resume s-1")
        #expect(agent.claudeSessionID == "s-1")
    }

    @Test func withoutAClosedAgentClaudeHasItStartsAFreshOneWhereTheTaskWorks() throws {
        let gone = TaskLayout(tabs: [], closedAgent: ClosedAgent(claudeSessionID: "s-1", directory: "/wt/old"))
        var worktree = task("t")
        worktree.worktree = "/wt/fix"
        for layout in [TaskLayout(tabs: []), gone] {
            let opening = NewTask.openAgent(
                in: layout, task: worktree, agent: WorkSettings.default.claude, integration: nil
            ) { _, _ in false }
            guard case let .opened(opened, _, agent, resumed) = opening else {
                Issue.record("expected a new agent tab, got \(String(describing: opening))")
                return
            }
            #expect(!resumed)
            #expect(opened.closedAgent == nil)
            let pane = try #require(opened.tabs.last?.tree.panes.first)
            #expect(pane.directory == "/wt/fix")
            let id = try #require(agent.claudeSessionID)
            #expect(pane.command == "claude --session-id \(id)")
        }
        #expect(NewTask.openAgent(in: gone, task: worktree, agent: nil, integration: nil) == nil)
    }

    @Test func aLayoutCachedBeforeClosedAgentsStillLoads() throws {
        let json = #"{"tabs":[],"activeTab":0}"#
        let layout = try JSONDecoder().decode(TaskLayout.self, from: Data(json.utf8))
        #expect(layout.closedAgent == nil)
    }

    @Test func withoutClaudeItOpensAShell() {
        let settings = WorkSettings(agents: [])
        let domain = Domain.empty.applying(NewTask.start(WorkTask(title: "t"), settings: settings, integration: nil))
        #expect(domain.layouts.values.first?.panes.map(\.role) == [.shell])
        #expect(domain.agents.isEmpty)
        #expect(domain.tasks.first?.timeline.last?.text.hasPrefix("started · shell") == true)
    }
}
