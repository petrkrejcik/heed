import Foundation

/// The new task dialog as a value: only a title. Typing edits it, `↩` creates the task, `⎋` cancels. A task started
/// from GitHub items or a PR also carries `context`, the agent's first prompt, shown but not edited.
public struct NewTaskForm: Sendable {
    public enum Outcome: Equatable, Sendable {
        case handled
        case create(title: String, context: String)
        case cancel
        /// The key means nothing here (it is swallowed anyway: nothing behind the dialog reacts to it).
        case ignored
    }

    public private(set) var title: String
    public let context: String
    public private(set) var error: String?

    public init(title: String = "", context: String = "") {
        self.title = title
        self.context = context
    }

    public mutating func handle(_ stroke: KeyStroke) -> Outcome {
        error = nil
        switch stroke {
        case .escape:
            return .cancel
        case KeyStroke("CR"), KeyStroke("CR", .command):
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                error = "type a title first"
                return .handled
            }
            return .create(title: trimmed, context: context)
        case KeyStroke("BS"):
            if !title.isEmpty { title.removeLast() }
        case KeyStroke("BS", .option), KeyStroke("w", .control):
            title = Self.deletingLastWord(title)
        case KeyStroke("u", .control):
            title = ""
        case KeyStroke("Space"):
            title += " "
        default:
            guard !stroke.isNamed, stroke.modifiers.subtracting(.option).isEmpty else { return .ignored }
            title += stroke.key
        }
        return .handled
    }

    /// Pasted text joins the title on one line.
    public mutating func paste(_ text: String) {
        title += text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    static func deletingLastWord(_ text: String) -> String {
        var text = text
        while text.last?.isWhitespace == true {
            text.removeLast()
        }
        while let last = text.last, !last.isWhitespace {
            text.removeLast()
        }
        return text
    }
}

public enum NewTask {
    /// Makes ids for new tasks and agent tabs; screenshots pin it so command lines never change between runs.
    public nonisolated(unsafe) static var newID: () -> String = { UUID().uuidString.lowercased() }

    /// The task pk just created, with one agent tab where it works (the main checkout, for a new task), its Claude
    /// session id picked up front. The changes are the task, its layout and its agent tab. Without Claude, a shell.
    public static func start(
        _ task: WorkTask, context: String = "", settings: WorkSettings, integration: IntegrationFiles?,
        now: Date = Date()
    ) -> [DomainChange] {
        var task = task
        task.lastActivity = now
        let tab = agentTab(in: task.directory, prompt: context, agent: settings.claude, integration: integration)
        task.record("started · \(settings.claude?.name ?? "shell") in \(Paths.abbreviate(task.directory))", at: now)
        var layout = TaskLayout(tabs: [tab.tab])
        if settings.shellSplit, tab.agent != nil { layout.add(shellTab(in: task.directory), show: true, focus: false) }
        var changes: [DomainChange] = [.taskUpserted(task), .layoutChanged(task: task.id, layout)]
        if let agent = tab.agent { changes.append(.agentChanged(pane: agent.pane, agent.tab)) }
        return changes
    }

    /// What a new agent for a task is offered (typed into its input, not sent): the note is the handover.
    public static func handoverPrompt(note: String) -> String { "Read the task note at \(note) and continue." }

    /// The Kibana PR `:review` means: `300162`, `#300162`, or the PR's URL (any tab of it). Nil for anything else,
    /// including another repo's PR.
    public static func reviewNumber(_ text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ref = PullRef(url: text) { return ref.repo == Kibana.repo ? ref.number : nil }
        guard let number = Int(text.hasPrefix("#") ? String(text.dropFirst()) : text), number > 0 else { return nil }
        return number
    }

    /// What the old agent is asked before the worktree is made.
    public static func notePrompt(note: String) -> String {
        "Update the task note at \(note): write what you learned so far. Reply ok when done."
    }

    /// What `W` types into the task's agent once the worktree exists: Claude moves the running session there, so the
    /// conversation carries on in the worktree.
    public static func moveCommand(to worktree: String) -> String { "/cd \(worktree)" }

    /// The tabs a worktree brings: `bootstrap` (pk's command line) in a terminal so its progress shows, then a tab
    /// per pinned command. Every tab starts its command at once.
    public static func setupTabs(worktree: String, bootstrap: String, settings: WorkSettings) -> [PaneTab] {
        let setup = PaneTab(id: newID(), title: "bootstrap", pane: PaneSpec(
            id: newID(), role: .shell, title: "bootstrap", directory: worktree, command: bootstrap
        ))
        let pinned = settings.commands.map { pinned in
            PaneTab(id: newID(), title: pinned.name, pane: PaneSpec(
                id: newID(), role: .command, title: pinned.name, directory: worktree,
                command: "\(pinned.command); \"${\(HeedEnvironment.binary):-true}\" command-exit $?"
            ))
        }
        return [setup] + pinned
    }

    /// The setup tabs, then a new agent with no prompt (a review, or a task whose agent is not running: what it is
    /// told is typed in as a draft once it is ready), and a shell when `shellSplit` asks. The agent is the one to
    /// focus.
    public static func worktreeTabs(
        worktree: String, bootstrap: String, settings: WorkSettings, integration: IntegrationFiles?
    ) -> (tabs: [PaneTab], agent: (pane: String, tab: AgentTab)?) {
        let agent = agentTab(in: worktree, prompt: "", agent: settings.claude, integration: integration)
        let shell = settings.shellSplit && agent.agent != nil ? [shellTab(in: worktree)] : []
        return (
            setupTabs(worktree: worktree, bootstrap: bootstrap, settings: settings) + [agent.tab] + shell,
            agent.agent
        )
    }

    /// `tabs` added to `layout` where the rules put them: the first to land in a pane is shown there, and the keys go
    /// to `focus` (a pane id) when given, else stay where they were.
    public static func adding(_ tabs: [PaneTab], to layout: TaskLayout, focus: String? = nil) -> TaskLayout {
        var layout = layout
        let keys = layout.focusedGroup
        var shown: [String: String] = [:]
        for tab in tabs {
            let group = layout.add(tab, show: false)
            if shown[group] == nil { shown[group] = tab.pane.id }
        }
        for pane in shown.values {
            layout.focus(pane: pane)
        }
        layout.focusedGroup = keys.flatMap { layout.group($0)?.id } ?? layout.groups.first?.id
        if let focus { layout.focus(pane: focus) }
        return layout
    }

    /// The layout once the agent in `pane` has moved to `worktree`: its tab works there (a relaunch resumes it
    /// there), `added` joins the task's tabs, and the agent has the keys. Nil when no tab has that pane.
    public static func movingAgent(
        _ pane: String, to worktree: String, in layout: TaskLayout, adding added: [PaneTab]
    ) -> TaskLayout? {
        guard layout.contains(pane: pane) else { return nil }
        var layout = layout
        layout.update(pane: pane) { $0.directory = worktree }
        return adding(added, to: layout, focus: pane)
    }

    /// What `tab.agent` does in a task.
    public enum AgentOpening: Equatable, Sendable {
        /// The task has an agent tab: go there.
        case existing(pane: String)
        /// A new agent tab in the agent's pane: the agent closed last, resumed where it worked, else a fresh one where
        /// the task works.
        case opened(TaskLayout, pane: String, AgentTab, resumed: Bool)
    }

    /// The task's agent, brought back when its tab was closed. `hasSession` says whether Claude still has a session
    /// for a folder (nil when it cannot tell). Nil without Claude.
    public static func openAgent(
        in layout: TaskLayout, task: WorkTask, agent: AgentProfile?, integration: IntegrationFiles?,
        hasSession: (_ id: String, _ directory: String) -> Bool? = { _, _ in nil }
    ) -> AgentOpening? {
        if let pane = layout.panes.first(where: { $0.role == .agent }) { return .existing(pane: pane.id) }
        guard let agent else { return nil }
        var layout = layout
        let tab: PaneTab
        let made: (pane: String, tab: AgentTab)
        var resumed = false
        if let closed = layout.closedAgent, hasSession(closed.claudeSessionID, closed.directory) != false,
           let command = agent.resumeCommand(
               id: closed.claudeSessionID,
               extraArguments: AgentIntegration.launchArguments(
                   agent: agent, claudeSessionID: closed.claudeSessionID, files: integration, resuming: true
               )
           )
        {
            let pane = PaneSpec(
                id: newID(), role: .agent, title: agent.name, directory: closed.directory, command: command
            )
            tab = PaneTab(id: newID(), title: "agent", pane: pane)
            made = (pane.id, AgentTab(activity: "resuming", claudeSessionID: closed.claudeSessionID))
            resumed = true
        } else {
            let built = agentTab(in: task.directory, prompt: "", agent: agent, integration: integration)
            guard let agent = built.agent else { return nil }
            (tab, made) = (built.tab, agent)
        }
        layout.closedAgent = nil
        layout.add(tab, show: true)
        return .opened(layout, pane: made.pane, made.tab, resumed: resumed)
    }

    /// A tab running `agent` on `prompt` in `directory`, with its own Claude session id. Without an agent, a shell.
    public static func agentTab(
        in directory: String, prompt: String, agent: AgentProfile?, integration: IntegrationFiles?
    ) -> (tab: PaneTab, agent: (pane: String, tab: AgentTab)?) {
        guard let agent else { return (shellTab(in: directory), nil) }
        let claudeSessionID = newID()
        let extra = AgentIntegration.launchArguments(agent: agent, claudeSessionID: claudeSessionID, files: integration)
        let pane = PaneSpec(
            id: newID(), role: .agent, title: agent.name, directory: directory,
            command: agent.launchCommand(prompt: prompt, extraArguments: extra)
        )
        let state = AgentTab(
            state: ObservedState(.idle, source: .guessed), activity: "starting",
            claudeSessionID: agent.sessionIDFlag == nil ? nil : claudeSessionID
        )
        return (PaneTab(id: newID(), title: "agent", pane: pane), (pane.id, state))
    }

    /// A plain shell tab in `directory`.
    public static func shellTab(in directory: String) -> PaneTab {
        PaneTab(
            id: newID(),
            title: "shell",
            pane: PaneSpec(id: newID(), role: .shell, title: "zsh", directory: directory)
        )
    }
}
