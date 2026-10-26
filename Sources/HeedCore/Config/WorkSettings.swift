import Foundation

/// What config says about running agents and terminals in tasks.
public struct WorkSettings: Hashable, Sendable, Codable {
    public var agents: [AgentProfile]
    /// `[commands]`: opened as tabs in a task's worktree when it gets one.
    public var commands: [PinnedCommand] = []
    /// On launch: ask which tasks' agents to resume, resume them all, or none.
    public var resumeOnLaunch: ResumePolicy
    /// Typed into a resumed agent that was mid-turn, once it is idle again. Empty turns it off.
    public var continuePrompt: String
    /// New tasks open a shell split beside the agent (`[sessions] shell_split`); off means one pane.
    public var shellSplit = false
    /// Whether panes outlive heed: `zmx` keeps each pane's terminal in a zmx session that heed reattaches to.
    public var persist: PanePersistence = .auto

    public init(
        agents: [AgentProfile] = AgentProfile.builtIn, resumeOnLaunch: ResumePolicy = .ask,
        continuePrompt: String = "Continue where you left off."
    ) {
        self.agents = agents
        self.resumeOnLaunch = resumeOnLaunch
        self.continuePrompt = continuePrompt
    }

    public static let `default` = WorkSettings()

    public func agent(_ name: String) -> AgentProfile? { agents.first { $0.name == name } }

    /// Claude: the agent new tasks start.
    public var claude: AgentProfile? { agent("claude") }
}

/// A command kept at hand in every worktree (test, build): its own tab, its exit code on the tab's glyph.
public struct PinnedCommand: Hashable, Sendable, Codable {
    public var name: String
    public var command: String

    public init(name: String, command: String) {
        self.name = name
        self.command = command
    }
}
