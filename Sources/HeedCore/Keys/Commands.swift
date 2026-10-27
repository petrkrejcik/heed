/// Every command the app can run. A key binding names one of these, `:` completes over them, and the `?` overlay is
/// drawn from them: one list, so a command never exists in one of those places and not the others.
public struct CommandSpec: Sendable, Equatable {
    public enum Group: String, Sendable, CaseIterable {
        case move = "Move & tasks"
        case panes = "Panes & tabs"
        case views = "Views & overlays"
        case modes = "Modes"
        case selection = "Selection"
    }

    public let name: String
    public let summary: String
    public let group: Group
    /// Argument placeholder shown in completion, e.g. `<n>` for `pin.jump`.
    public let arguments: String?

    public init(_ name: String, _ summary: String, _ group: Group, arguments: String? = nil) {
        self.name = name
        self.summary = summary
        self.group = group
        self.arguments = arguments
    }
}

public enum Commands {
    public static let all: [CommandSpec] = [
        // Move & tasks
        .init("row.next", "next task / row", .move),
        .init("row.prev", "previous task / row", .move),
        .init("row.first", "first task / row", .move),
        .init("row.last", "last task / row", .move),
        .init("row.halfpage.down", "half a page down (ten rows)", .move),
        .init("row.halfpage.up", "half a page up (ten rows)", .move),
        .init("group.next", "first row of the next group (sidebar group, repo)", .move),
        .init("group.prev", "first row of this group, or of the one before", .move),
        .init("task.filter", "filter the current view (typed in the status bar)", .move),
        .init("filter.clear", "clear the current view's filter", .move),
        .init("task.attention", "next task needing you", .move),
        .init("task.pin", "pin / unpin task (in its note)", .move),
        .init("task.back", "back to previous task", .move),
        .init(
            "task.open", "go to the task matching these words; a To Do one becomes In Progress", .move,
            arguments: "<words>"
        ),
        .init("pin.jump", "jump to pinned task", .move, arguments: "<1-9>"),
        .init("task.new", "new task: only a title", .move, arguments: "[title]"),
        .init(
            "task.status", "set the task's status in its note (done and dropped close its terminals)", .move,
            arguments: "<done|blocked|in progress|review|todo|dropped>"
        ),
        .init(
            "task.worktree",
            "add a worktree: the agent updates the note, then the worktree, bootstrap and a new agent (again: stop waiting)",
            .move
        ),
        .init("task.review", "review a PR: a task, its worktree, bootstrap and an agent", .move, arguments: "<number>"),
        .init("tasks.refresh", "read every task from pk again", .move),
        .init("kibana.run", "run Kibana for this task in a new tab (pk kbn)", .move),
        .init("resume", "pick up where you left off: the agents to resume, as on launch", .move),
        // Panes & tabs
        .init("pane.left", "focus pane left", .panes),
        .init("pane.right", "focus pane right", .panes),
        .init("pane.up", "focus pane above", .panes),
        .init("pane.down", "focus pane below", .panes),
        .init("pane.split.right", "split right", .panes),
        .init("pane.split.below", "split below", .panes),
        .init("pane.zoom", "zoom pane", .panes),
        .init("pane.close", "close pane", .panes),
        .init("tab.close", "close the tab, every pane in it", .panes),
        .init("tab.next", "next tab", .panes),
        .init("tab.prev", "previous tab", .panes),
        .init("tab.new", "new tab with shell", .panes),
        .init("tab.go", "go to tab n", .panes, arguments: "<n>"),
        .init("browser.new", "new tab with a web page (no address: type one)", .panes, arguments: "[url]"),
        .init("browser.back", "web page: back", .panes),
        .init("browser.forward", "web page: forward", .panes),
        .init("browser.reload", "web page: reload, or stop loading", .panes),
        .init("browser.location", "web page: type an address", .panes),
        .init("browser.zoom.in", "web page: zoom in", .panes),
        .init("browser.zoom.out", "web page: zoom out", .panes),
        .init("browser.zoom.reset", "web page: actual size", .panes),
        .init("browser.external", "web page: open it in your default browser", .panes),
        // Views & overlays
        .init("view", "switch view", .views, arguments: "<tasks|inbox|issues|prs>"),
        .init("view.tasks", "tasks", .views),
        .init("view.inbox", "inbox", .views),
        .init("view.issues", "issues", .views),
        .init("view.prs", "pull requests", .views),
        .init("overlay.pr", "PR overlay for this task (toggle)", .views),
        .init("overlay.item", "open the PR or issue under the cursor; in Tasks, the task's PR (toggle)", .views),
        .init("overlay.diff", "diff overlay: commits, staged, unstaged", .views),
        .init("overlay.help", "keys & states", .views),
        .init("overlay.close", "close overlay", .views),
        .init("pr.task", "jump from a PR to its task", .views),
        .init("jump.back", "back", .views),
        .init(
            "open.browser",
            "open in the browser: the item under the cursor; in Tasks its PR or issue (a picker when there are both, Kibana when there are none)",
            .views
        ),
        .init("open.repo", "open the repo under the cursor on GitHub", .views),
        .init("links.pick", "pick the task's PR or issue to open in the browser", .views),
        .init("open.reader", "read inbox item, issue or PR", .views),
        .init("inspector.toggle", "collapse / expand the inspector", .views),
        .init("sidebar.toggle", "collapse / expand the tasks sidebar", .views),
        .init("config.edit", "open config.toml in $EDITOR", .views),
        .init("agents.stop", "stop every agent and shell in every pane (with [sessions] persist = \"zmx\")", .views),
        .init("tools.detect", "find git and gh again (login shell PATH, usual places, [tools])", .views),
        .init("app.quit", "quit Heed", .views),
        .init(
            "settings.open", "open Settings, on a section (general, agents, keys)", .views,
            arguments: "[section]"
        ),
        .init("app.activate", "bring Heed's window to the front, as the global shortcut does", .views),
        .init("welcome", "show the getting-started checks again", .views),
        // Modes
        .init("mode.normal", "back to NORMAL", .modes),
        .init("mode.insert", "INSERT into the focused pane", .modes),
        .init("mode.visual", "VISUAL: select, then act", .modes),
        .init("mode.command", "COMMAND line", .modes),
        .init("mode.hint", "HINT: jump to anything", .modes),
        .init("hint.insert", "jump and enter INSERT", .modes),
        .init("command.submit", "run the command line", .modes),
        .init("command.complete", "complete", .modes),
        // Selection
        .init("select.toggle", "toggle row", .selection),
        .init("github.sync", "sync GitHub now", .selection),
        .init("items.start", "start one task from the picked items", .selection),
        .init("items.read", "mark read", .selection),
        .init("items.filter", "cycle the filter chips", .selection),
        .init("issues.repo.next", "next repo in the Issues repo column", .selection),
        .init("issues.repo.prev", "previous repo in the Issues repo column", .selection),
        .init("issues.repo", "show one repo's issues (no name: every repo)", .selection, arguments: "[name]"),
        .init("pr.start", "start a new task from this PR", .selection),
        .init("diff.hunk.next", "next hunk", .selection),
        .init("diff.hunk.prev", "previous hunk", .selection),
        .init("diff.file.next", "next file", .selection),
        .init("diff.file.prev", "previous file", .selection),
        .init("diff.scope.next", "next scope: all, committed, staged, unstaged", .selection),
        .init("diff.scope.prev", "previous scope", .selection),
        .init("diff.commit", "show one commit (cycles)", .selection),
        .init("diff.split", "unified / split", .selection),
        .init("diff.ask", "ask the agent about this hunk", .selection),
        .init("diff.copy", "copy path:line", .selection),
        .init("diff.edit", "open the file in the editor", .selection),
    ]

    public static let byName: [String: CommandSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    public static func spec(_ name: String) -> CommandSpec? { byName[name] }

    /// Names that start with `prefix`, for `:` completion.
    public static func complete(_ prefix: String) -> [CommandSpec] {
        all.filter { $0.name.hasPrefix(prefix) }
    }
}
