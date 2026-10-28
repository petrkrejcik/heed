import Foundation
@testable import HeedCore
import Testing

private func task(_ id: String, status: TaskStatus = .inProgress, pinned: Bool = false, ago: Double = 0) -> WorkTask {
    WorkTask(
        id: id,
        title: id,
        status: status,
        pinned: pinned,
        lastActivity: Date(timeIntervalSince1970: 1_000_000 - ago)
    )
}

private func agentLayout(_ task: String) -> TaskLayout {
    TaskLayout(tabs: [PaneTab(
        title: "agent", pane: PaneSpec(id: "\(task)-a", role: .agent, title: "claude", directory: "/")
    )])
}

/// Pinned p; In Progress a, b; Blocked c; Ready for Review r; Done d.
private let mixed = [
    task("p", pinned: true), task("a", ago: 1), task("b", ago: 2), task("c", status: .blocked),
    task("r", status: .readyForReview), task("d", status: .done),
]

struct SidebarSectionsTests {
    @Test func aCollapsedSectionKeepsItsHeaderAndCountButNotItsRows() throws {
        let list = TaskList(mixed, collapsed: [.inProgress])
        let section = try #require(list.sections.first { $0.group == .inProgress })
        #expect(section.collapsed && section.tasks.map(\.id) == ["a", "b"])
        #expect(list.ordered.map(\.id) == ["p", "c", "r", "d"])
        #expect(list.all.map(\.id) == ["p", "a", "b", "c", "r", "d"])
        #expect(TaskList(mixed, collapsed: []).ordered.count == 6)
    }

    @Test func movesSkipCollapsedRows() {
        let list = TaskList(mixed, collapsed: [.inProgress, .done])
        // `{`/`}` walk the open sections' rows.
        let keys = list.ordered.map { list.group(of: $0.id)?.rawValue ?? "" }
        #expect(keys == ["Pinned", "Blocked", "Ready for Review"])
        #expect(RowGroups.next(keys, from: 0) == 1)
        #expect(RowGroups.previous(keys, from: 2) == 1)
        // `G` and line numbers count only those rows.
        #expect(list.ordered.indices.last == 2)
        #expect(list.ordered.indices.map { list.lineNumber(of: $0, cursor: 0) } == [1, 1, 2])
    }

    @Test func theCursorStaysOnItsTaskElseTakesTheNextRow() {
        let open = TaskList(mixed, collapsed: [.done])
        let before = open.ordered
        // Still a row: on it, wherever it went.
        #expect(open.row(for: "c", before: before, cursor: 0) == 3)
        // Its section collapsed: the first row that was below it.
        let closed = TaskList(mixed, collapsed: [.done, .inProgress])
        #expect(closed.row(for: "b", before: before, cursor: 2) == 1)
        #expect(closed.ordered[1].id == "c")
        // Nothing below it is left: the nearest row above.
        let bottom = TaskList(mixed, collapsed: [.done, .readyForReview])
        #expect(bottom.row(for: "r", before: before, cursor: 4) == 3)
        #expect(bottom.ordered[3].id == "c")
        // No task, or an empty list.
        #expect(open.row(for: nil, before: before, cursor: 99) == 4)
        #expect(TaskList([]).row(for: "a", before: before, cursor: 3) == 0)
    }

    @Test func theTaskYouAreOnOpensTheCollapsedSectionItMovesIntoWhenItHasTabs() {
        let before = Domain(tasks: mixed, layouts: ["a": agentLayout("a")])
        var after = before
        after.apply(.taskUpserted(task("a", status: .done, ago: 1)))
        #expect(after.opening(sectionOf: "a", movedFrom: before) == .collapsedChanged([.toDo, .dropped]))
        // Not the task you are on, or none.
        #expect(after.opening(sectionOf: "b", movedFrom: before) == nil)
        #expect(after.opening(sectionOf: nil, movedFrom: before) == nil)
        // Without tabs the section stays collapsed (the cursor moves on instead).
        var bare = before
        bare.apply(.taskUpserted(task("b", status: .done, ago: 2)))
        #expect(bare.opening(sectionOf: "b", movedFrom: before) == nil)
        // Into an open section, or not moving at all: nothing to open.
        var blocked = before
        blocked.apply(.taskUpserted(task("a", status: .blocked, ago: 1)))
        #expect(blocked.opening(sectionOf: "a", movedFrom: before) == nil)
        #expect(before.opening(sectionOf: "a", movedFrom: before) == nil)
    }

    /// The case behind the task: an agent or Obsidian sets a task Done while its agent runs.
    @Test func aTaskSetDoneOutsideHeedKeepsItsTabsAndAgentAndMovesSection() throws {
        let agents = ["a-a": AgentTab(state: ObservedState(.working), activity: "running jest")]
        let before = Domain(tasks: mixed, layouts: ["a": agentLayout("a")], agents: agents)
        // As pk lists it after the note changed.
        let listed = mixed.map { task in
            PkTask(
                id: task.id, title: task.title, status: (task.id == "a" ? TaskStatus.done : task.status).rawValue,
                pinned: task.pinned
            )
        }
        let changes = TaskSync.reconcile(listed, into: before.tasks)
        var after = before.applying(changes)
        #expect(after.task("a")?.status == .done)
        #expect(after.layouts["a"] == before.layouts["a"])
        #expect(after.agents == agents)
        if let opening = after.opening(sectionOf: "a", movedFrom: before) { after.apply(opening) }
        let list = TaskList(after.tasks, layouts: after.layouts, agents: after.agents, collapsed: after.collapsed)
        #expect(list.group(of: "a") == .done)
        #expect(list.index(of: "a") != nil)
        #expect(list.rollup(of: "a").agent?.state == .working)
    }

    @Test func collapsedSectionsRoundTripThroughTheCache() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("heed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = DomainStore(file: file, writeDelay: .zero)
        await store.apply(.collapsedChanged([.done, .blocked]))
        await store.flush()
        #expect(await DomainStore.load(from: file).collapsed == [.done, .blocked])
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let domain = try #require(json["domain"] as? [String: Any])
        #expect(domain["collapsed"] as? [String] == ["Blocked", "Done"])
    }

    @Test func aCacheFromBeforeSectionsLoadsWithTheDefaults() throws {
        var json = try #require(JSONSerialization
            .jsonObject(with: JSONEncoder().encode(Fixtures.tasks)) as? [String: Any])
        json["collapsed"] = nil
        let old = try JSONDecoder().decode(Domain.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.collapsed == TaskGroup.collapsedByDefault)
        #expect(old.tasks == Fixtures.tasks.tasks)
        json["collapsed"] = ["Done", "Someday"]
        let unknown = try JSONDecoder().decode(Domain.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(unknown.collapsed == [.done])
    }

    @Test func sectionsByName() {
        #expect(TaskGroup.named("todo") == .toDo)
        #expect(TaskGroup.named("wip") == .inProgress)
        #expect(TaskGroup.named("Blocked") == .blocked)
        #expect(TaskGroup.named("review") == .readyForReview)
        #expect(TaskGroup.named("done") == .done)
        #expect(TaskGroup.named("drop") == .dropped)
        #expect(TaskGroup.named("pinned") == .pinned)
        #expect(TaskGroup.named("other") == .other)
        #expect(TaskGroup.named("later") == nil)
        #expect(TaskGroup(status: TaskStatus(rawValue: "Someday")) == .other)
        #expect(CommandAliases.resolve("section done") == CommandInvocation(
            name: "section.toggle",
            arguments: ["done"]
        ))
        #expect(DefaultKeys.normal.contains { $0.0 == "za" && $0.1 == "section.toggle" })
        #expect(Commands.spec("section.toggle") != nil)
    }
}
