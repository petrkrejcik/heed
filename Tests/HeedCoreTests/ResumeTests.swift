import Foundation
@testable import HeedCore
import Testing

/// A task with one agent tab per entry of `agents` (pane `<id>-<n>`, Claude session `<id>-s<n>` unless nil).
private func world(_ tasks: [(id: String, agents: [(AgentState, String?)])]) -> Domain {
    var domain = Domain()
    for (id, agents) in tasks {
        domain.tasks.append(WorkTask(id: id, title: id, notePath: "/notes/Projects/\(id).md"))
        let tabs = agents.indices.map { index in
            PaneTab(title: "agent", pane: PaneSpec(
                id: "\(id)-\(index)", role: .agent, title: "claude", directory: "/w/\(id)"
            ))
        }
        let shell = PaneTab(title: "shell", pane: PaneSpec(
            id: "\(id)-shell", role: .shell, title: "zsh", directory: "/w/\(id)"
        ))
        domain.layouts[id] = TaskLayout(tabs: tabs + [shell])
        for (index, agent) in agents.enumerated() {
            domain.agents["\(id)-\(index)"] = AgentTab(state: ObservedState(agent.0), claudeSessionID: agent.1)
        }
    }
    return domain
}

struct ResumeTests {
    @Test func modesFollowTheStateTheTaskWasIn() {
        let domain = world([
            ("w", [(.working, "w-s0")]), ("b", [(.blocked, "b-s0")]), ("a", [(.asking, "a-s0")]),
            ("d", [(.done, "d-s0")]), ("n", [(.working, nil)]),
        ])
        let candidates = Resume.candidates(domain: domain, settings: .default, integration: nil, newID: { "new" })
        let modes = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.mode) })
        #expect(modes == [
            "w": .resumeThenContinue, "b": .resumeOnly, "a": .resumeOnly, "d": .leftClosed, "n": .startFresh,
        ])
        #expect(candidates.first { $0.id == "w" }?.command == "claude --resume w-s0")
        // No session to resume: a fresh agent with its own new id, pointed at the task note.
        let fresh = candidates.first { $0.id == "n" }?.panes.first
        #expect(fresh?.command
            == "claude --session-id new 'Read the task note at /notes/Projects/n.md and continue.'")
        #expect(fresh?.claudeSessionID == "new")
        #expect(fresh?.fresh == true)
    }

    @Test func eachAgentTabResumesItsOwnSession() throws {
        let domain = world([("t", [(.working, "first"), (.idle, "second")])])
        let candidate = try #require(Resume.candidates(domain: domain, settings: .default, integration: nil).first)
        #expect(candidate.panes.map(\.pane) == ["t-0", "t-1"])
        #expect(candidate.panes.map(\.command) == ["claude --resume first", "claude --resume second"])
        #expect(candidate.paneCount == 3)
        #expect(candidate.mode == .resumeThenContinue)
        #expect(candidate.note == nil)
    }

    @Test func aSessionClaudeDroppedStartsThatTabFresh() throws {
        let domain = world([("t", [(.working, "kept"), (.idle, "gone")])])
        let candidate = try #require(Resume.candidates(
            domain: domain, settings: .default, integration: nil,
            hasSession: { id, _ in id == "kept" }, newID: { "new" }
        ).first)
        #expect(candidate.panes.map(\.fresh) == [false, true])
        #expect(candidate.mode == .resumeThenContinue)
        #expect(candidate.note == "Some agents start again from the task note.")
        let gone = try #require(Resume.candidates(
            domain: domain, settings: .default, integration: nil, hasSession: { _, _ in false }, newID: { "new" }
        ).first)
        #expect(gone.mode == .startFresh)
    }

    /// A task set Done outside Heed keeps its agent tabs, so it is offered too, though its section is collapsed.
    @Test func tasksWithoutAgentTabsAreNotOffered() {
        var domain = world([("t", [(.working, "s")]), ("done", [(.working, "s2")])])
        domain.tasks[1].status = .done
        domain.tasks.append(WorkTask(id: "bare", title: "bare"))
        #expect(Resume.candidates(domain: domain, settings: .default, integration: nil).map(\.id) == ["t", "done"])
    }

    @Test func resumeKeepsHooksButNotTheSessionIDFlag() {
        let files = IntegrationFiles(directory: URL(fileURLWithPath: "/tmp/h"))
        let domain = world([("w", [(.working, "abc")])])
        let pane = Resume.candidates(domain: domain, settings: .default, integration: files).first?.panes.first
        #expect(pane?.command == "claude --settings /tmp/h/claude-hooks.json --resume abc")
        // The dialog leaves Heed's own settings out.
        #expect(pane?.display == "claude --resume abc")
    }

    @Test func formTicksActiveTasksAndToggles() {
        var domain = world([("w", [(.working, "a")]), ("d", [(.done, "b")])])
        // Listed as the sidebar lists them: the most recently active first.
        domain.tasks[0].lastActivity = Date(timeIntervalSince1970: 2)
        domain.tasks[1].lastActivity = Date(timeIntervalSince1970: 1)
        var form = ResumeForm(candidates: Resume.candidates(domain: domain, settings: .default, integration: nil))
        #expect(form.chosen.map(\.id) == ["w"])
        _ = form.handle(KeyStroke("j"))
        _ = form.handle(KeyStroke("Space"))
        #expect(form.handle(KeyStroke("CR", .command)) == .resume(form.chosen))
        #expect(Set(form.chosen.map(\.id)) == ["w", "d"])
        #expect(form.handle(.escape) == .startEmpty)
    }

    @Test func claudeSessionFilesAreFoundByEncodedDirectory() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let folder = "\(home)/.claude/projects/-Users-me-www-kibana-worktrees-x"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(folder)/abc.jsonl", contents: Data())
        let directory = "/Users/me/www/kibana.worktrees/x"
        #expect(AgentIntegration.hasSession(agent: "claude", id: "abc", directory: directory, home: home) == true)
        #expect(AgentIntegration.hasSession(agent: "claude", id: "nope", directory: directory, home: home) == false)
        #expect(AgentIntegration.hasSession(agent: "mytool", id: "abc", directory: "/", home: home) == nil)
    }
}
