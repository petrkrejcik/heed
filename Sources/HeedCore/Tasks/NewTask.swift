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
        let tab = agentTab(
            in: task.directory, prompt: context, agent: settings.claude, shellSplit: settings.shellSplit,
            integration: integration
        )
        task.record("started · \(settings.claude?.name ?? "shell") in \(Paths.abbreviate(task.directory))", at: now)
        var changes: [DomainChange] = [
            .taskUpserted(task), .layoutChanged(task: task.id, TaskLayout(tabs: [tab.tab])),
        ]
        if let agent = tab.agent { changes.append(.agentChanged(pane: agent.pane, agent.tab)) }
        return changes
    }

    /// What an agent in a new worktree is told: the note is the handover, since a running Claude cannot change folder.
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
        "Update the task note at \(note): write the plan and what you learned so far. Reply ok when done."
    }

    /// The tabs a task gets with its new worktree, added after the ones it has: `bootstrap` (pk's command line) in a
    /// terminal so its progress shows, a tab per pinned command, then a new agent on `prompt`. Every pane starts
    /// its command at once. The agent's tab comes last; it is the one to show.
    public static func worktreeTabs(
        worktree: String, prompt: String, bootstrap: String, settings: WorkSettings, integration: IntegrationFiles?
    ) -> (tabs: [PaneTab], agent: (pane: String, tab: AgentTab)?) {
        let setup = PaneTab(id: newID(), title: "bootstrap", tree: .leaf(PaneSpec(
            id: newID(), role: .shell, title: "bootstrap", directory: worktree, command: bootstrap
        )))
        let pinned = settings.commands.map { pinned in
            PaneTab(id: newID(), title: pinned.name, tree: .leaf(PaneSpec(
                id: newID(), role: .command, title: pinned.name, directory: worktree,
                command: "\(pinned.command); \"${\(HeedEnvironment.binary):-true}\" command-exit $?"
            )))
        }
        let agent = agentTab(
            in: worktree, prompt: prompt, agent: settings.claude, shellSplit: settings.shellSplit,
            integration: integration
        )
        return ([setup] + pinned + [agent.tab], agent.agent)
    }

    /// A tab running `agent` on `prompt` in `directory`, with its own Claude session id, and a shell split beside it
    /// when asked. Without an agent, a shell.
    public static func agentTab(
        in directory: String, prompt: String, agent: AgentProfile?, shellSplit: Bool = false,
        integration: IntegrationFiles?
    ) -> (tab: PaneTab, agent: (pane: String, tab: AgentTab)?) {
        guard let agent else {
            let shell = PaneSpec(id: newID(), role: .shell, title: "zsh", directory: directory)
            return (PaneTab(id: newID(), title: "shell", tree: .leaf(shell)), nil)
        }
        let claudeSessionID = newID()
        let extra = AgentIntegration.launchArguments(agent: agent, claudeSessionID: claudeSessionID, files: integration)
        let pane = PaneSpec(
            id: newID(), role: .agent, title: agent.name, directory: directory,
            command: agent.launchCommand(prompt: prompt, extraArguments: extra)
        )
        var tab = PaneTab(id: newID(), title: "agent", tree: .leaf(pane))
        if shellSplit {
            tab.split(.horizontal, with: PaneSpec(id: newID(), role: .shell, title: "zsh", directory: directory))
            tab.focused = pane.id
        }
        let state = AgentTab(
            state: ObservedState(.idle, source: .guessed), activity: "starting",
            claudeSessionID: agent.sessionIDFlag == nil ? nil : claudeSessionID
        )
        return (tab, (pane.id, state))
    }
}
