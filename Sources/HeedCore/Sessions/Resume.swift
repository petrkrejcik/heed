import Foundation

public enum ResumePolicy: String, Hashable, Sendable, Codable, CaseIterable {
    case ask, always, never
}

/// What happens to one task's agents on launch. design/screens/Resume.png.
public struct ResumeCandidate: Identifiable, Hashable, Sendable {
    public enum Mode: String, Hashable, Sendable {
        /// Was mid-turn: resume, then type the continue prompt once idle (not sent).
        case resumeThenContinue = "resume, then continue"
        /// Was waiting on you (blocked, asking): resume only; the agent asks again.
        case resumeOnly = "resume only"
        /// Claude no longer has any of its sessions: start again from the task note.
        case startFresh = "start fresh"
        /// Idle or finished: offered, not ticked.
        case leftClosed = "left closed"
    }

    /// One agent tab: the line typed into it, and its Claude session id from then on.
    public struct Pane: Hashable, Sendable {
        public let pane: String
        public let command: String
        /// `command` without Heed's own hook settings, for the dialog.
        public let display: String
        public let claudeSessionID: String?
        /// Started fresh, because Claude no longer has the tab's session.
        public let fresh: Bool
        /// Typed into the agent's input once it is ready, never sent: the agent only works when you press Return.
        public var draft: String?
    }

    public var id: String { task.id }
    public let task: WorkTask
    /// The task's most urgent agent state, as it was.
    public let state: ObservedState
    public let mode: Mode
    public let panes: [Pane]
    public let paneCount: Int

    /// Whether it is ticked by default.
    public var defaultSelected: Bool { mode != .leftClosed }

    /// The first agent's line.
    public var command: String { panes.first?.command ?? "" }

    /// "was working", "was blocked on a permission prompt", "idle".
    public var summary: String {
        switch state.state {
        case .working: "was working"
        case .blocked: "was blocked on a permission prompt"
        case .asking: "was asking\(state.reason.map { " \($0)" } ?? "")"
        case .limited: "was rate limited"
        case .done: "had finished"
        case .idle, .exited: "idle"
        }
    }

    public var note: String? {
        switch mode {
        case .resumeOnly where state.state == .blocked: "The prompt is gone after a restart. The agent will ask again."
        case .startFresh: "Claude no longer has this task's sessions; its agents start again from the task note."
        default: panes.contains(where: \.fresh) ? "Some agents start again from the task note." : nil
        }
    }
}

public enum Resume {
    /// The tasks worth offering on launch: every listed task with an agent tab. `hasSession` answers whether Claude
    /// still has a session id for a directory (nil when unknown); it does file IO, so call this off the main actor.
    /// `newID` gives the Claude session id of an agent that starts fresh.
    public static func candidates(
        domain: Domain, settings: WorkSettings, integration: IntegrationFiles?,
        hasSession: (_ id: String, _ directory: String) -> Bool? = { _, _ in nil },
        newID: () -> String = { NewTask.newID() }
    ) -> [ResumeCandidate] {
        let list = TaskList(domain.tasks, layouts: domain.layouts, agents: domain.agents)
        guard let agent = settings.claude else { return [] }
        return list.all.compactMap { task -> ResumeCandidate? in
            guard let layout = domain.layouts[task.id] else { return nil }
            let agentPanes = layout.panes.filter { $0.role == .agent }
            guard !agentPanes.isEmpty else { return nil }
            let panes = agentPanes.map { pane -> ResumeCandidate.Pane in
                if let id = domain.agents[pane.id]?.claudeSessionID, hasSession(id, pane.directory) != false,
                   agent.resumeArguments != nil
                {
                    let line = { (files: IntegrationFiles?) in
                        agent.resumeCommand(id: id, extraArguments: AgentIntegration.launchArguments(
                            agent: agent, claudeSessionID: id, files: files, resuming: true
                        )) ?? ""
                    }
                    return ResumeCandidate.Pane(
                        pane: pane.id, command: line(integration), display: line(nil), claudeSessionID: id,
                        fresh: false
                    )
                }
                let id = newID()
                let line = { (files: IntegrationFiles?) in
                    agent.launchCommand(prompt: "", extraArguments: AgentIntegration.launchArguments(
                        agent: agent, claudeSessionID: id, files: files
                    ))
                }
                return ResumeCandidate.Pane(
                    pane: pane.id, command: line(integration), display: line(nil),
                    claudeSessionID: agent.sessionIDFlag == nil ? nil : id, fresh: true,
                    draft: task.notePath.map(NewTask.handoverPrompt)
                )
            }
            let state = list.rollup(of: task.id).agent ?? ObservedState(.idle, source: .guessed)
            let active = [.working, .blocked, .asking, .limited].contains(state.state)
            let mode: ResumeCandidate.Mode = if panes.allSatisfy(\.fresh) {
                active ? .startFresh : .leftClosed
            } else {
                switch state.state {
                case .working, .limited: .resumeThenContinue
                case .blocked, .asking: .resumeOnly
                case .idle, .done, .exited: .leftClosed
                }
            }
            let nudge = settings.continuePrompt.isEmpty ? nil : settings.continuePrompt
            let drafted = panes.map { pane in
                var pane = pane
                if !pane.fresh, mode == .resumeThenContinue { pane.draft = nudge }
                return pane
            }
            return ResumeCandidate(
                task: task, state: state, mode: mode, panes: drafted, paneCount: layout.panes.count
            )
        }
    }
}

/// The resume dialog as a value: which candidates are ticked, the cursor, and the keys.
public struct ResumeForm: Sendable {
    public enum Outcome: Equatable, Sendable {
        case handled
        /// Resume these candidates.
        case resume([ResumeCandidate])
        /// Start without resuming anything.
        case startEmpty
    }

    public let candidates: [ResumeCandidate]
    public private(set) var selected: Set<String>
    public private(set) var cursor = 0

    public init(candidates: [ResumeCandidate]) {
        self.candidates = candidates
        selected = Set(candidates.filter(\.defaultSelected).map(\.id))
    }

    public var chosen: [ResumeCandidate] { candidates.filter { selected.contains($0.id) } }

    public mutating func handle(_ stroke: KeyStroke) -> Outcome {
        switch stroke {
        case KeyStroke("j"), KeyStroke("Down"):
            cursor = min(cursor + 1, max(candidates.count - 1, 0))
        case KeyStroke("k"), KeyStroke("Up"):
            cursor = max(cursor - 1, 0)
        case KeyStroke("Space"), KeyStroke("x"):
            guard candidates.indices.contains(cursor) else { break }
            let id = candidates[cursor].id
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        case KeyStroke("CR", .command), KeyStroke("CR"):
            return .resume(chosen)
        case .escape:
            return .startEmpty
        default:
            break
        }
        return .handled
    }
}
