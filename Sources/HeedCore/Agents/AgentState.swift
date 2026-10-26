/// What an agent is doing, as reported by its hooks.
/// Each state has its own glyph shape, not only a color.
public enum AgentState: String, CaseIterable, Sendable, Codable {
    /// Prompt submitted or a tool is running. Spinner ring.
    case working
    /// Session open, nothing running. Hollow circle.
    case idle
    /// Waiting on a permission prompt. Amber diamond.
    case blocked
    /// Interviewing you: open questions to answer. Violet circle with `?`.
    case asking
    /// Turn finished, ready for review. Green check.
    case done
    /// Rate limited; falls back per the agent's `fallback`. Dashed ring.
    case limited
    /// The agent process ended; the shell lives on. Hollow square.
    case exited

    /// Blocked and asking agents are the ones `ga` cycles through and the title bar counts.
    public var needsYou: Bool { self == .blocked || self == .asking }

    public var summary: String {
        switch self {
        case .working: "Prompt submitted or a tool is running."
        case .idle: "Session open, nothing running."
        case .blocked: "Waiting on a permission prompt."
        case .asking: "Interviewing you: open questions to answer."
        case .done: "Turn finished. Ready for review."
        case .limited: "Rate limited. Falls back per config."
        case .exited: "Agent process ended, shell still alive."
        }
    }
}

/// Where a state came from. Guessed states get a dotted ring so they are trusted less.
public enum StateSource: String, Sendable, Codable {
    /// The agent's hook reported it.
    case reported
    /// Assumed by Heed until the first hook arrives (an agent tab just started or resuming).
    case guessed
}

public struct ObservedState: Hashable, Sendable, Codable {
    public var state: AgentState
    public var source: StateSource
    public var reason: String?

    public init(_ state: AgentState, source: StateSource = .reported, reason: String? = nil) {
        self.state = state
        self.source = source
        self.reason = reason
    }
}
