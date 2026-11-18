@testable import HeedCore
import Testing

private func items(_ entries: [MenuEntry]) -> [MenuItem] {
    entries.flatMap { entry -> [MenuItem] in
        switch entry {
        case let .item(item): [item]
        case let .submenu(_, entries): items(entries)
        case .header, .separator: []
        }
    }
}

private func statusMenu(_ task: WorkTask) -> [MenuEntry] {
    ContextMenus.task(task).lazy.compactMap { if case let .submenu("Status", entries) = $0 { entries } else { nil } }
        .first ?? []
}

struct ContextMenuTests {
    @Test func taskMenuIsItsTitleThenStatus() {
        let menu = ContextMenus.task(WorkTask(title: "Fix the flyout"))
        #expect(menu.count == 2)
        #expect(menu.first == .header("Fix the flyout"))
        #expect(menu.last == .submenu("Status", statusMenu(WorkTask(title: "t"))))
    }

    @Test func aTaskWithAPullHasItsPageFirst() {
        let task = WorkTask(title: "Fix the flyout", pr: "https://github.com/elastic/kibana/pull/7")
        let menu = ContextMenus.task(task)
        #expect(menu.count == 3)
        guard case let .item(item) = menu[1] else { return #expect(Bool(false), "no PR item") }
        #expect(item.title == "Pull request")
        #expect(item.command.name == "overlay.item")
    }

    @Test func statusListsEveryStatusInSidebarOrder() {
        let entries = statusMenu(WorkTask(title: "t"))
        let titles = ["To Do", "In Progress", "Blocked", "Ready for Review", "Done…", "Dropped…"]
        #expect(items(entries).map(\.title) == titles)
        #expect(entries[4] == .separator)
        #expect(Set(ContextMenus.statusOrder) == Set(TaskStatus.all))
    }

    @Test func eachStatusRunsTaskStatus() {
        for (item, status) in zip(items(statusMenu(WorkTask(title: "t"))), ContextMenus.statusOrder) {
            #expect(item.command.name == "task.status")
            #expect(TaskStatus.named(item.command.arguments.joined(separator: " ")) == status)
            #expect(item.enabled)
        }
    }

    @Test func ownStatusIsChecked() {
        let checked = items(statusMenu(WorkTask(title: "t", status: .blocked))).filter(\.checked).map(\.title)
        #expect(checked == ["Blocked"])
        let other = WorkTask(title: "t", status: TaskStatus(rawValue: "Someday"))
        #expect(items(statusMenu(other)).allSatisfy { !$0.checked })
    }

    @Test func keyIsAnyBindingNamingTheStatus() throws {
        let bindings = try [("dd", "task.status done"), ("di", "task.status in-progress"), ("dw", "task.status wip")]
            .map { try (keys: KeyNotation.parse($0.0), command: $0.1) }
        let menu = items(statusMenu(WorkTask(title: "t")))
        let inProgress = try #require(menu.first { $0.title == "In Progress" })
        #expect(inProgress.keys(in: bindings).map(KeyNotation.format) == ["di", "dw"])
        let done = try #require(menu.first { $0.title == "Done…" })
        #expect(done.keys(in: bindings).map(KeyNotation.format) == ["dd"])
        let toDo = try #require(menu.first { $0.title == "To Do" })
        #expect(toDo.keys(in: bindings).isEmpty)
        #expect(toDo.typed == ":status todo")
    }

    @Test func defaultKeysCoverAllButToDoAndDropped() throws {
        let bindings = try DefaultKeys.normal.map { try (keys: KeyNotation.parse($0.0), command: $0.1) }
        let bound = items(statusMenu(WorkTask(title: "t"))).filter { !$0.keys(in: bindings).isEmpty }.map(\.title)
        #expect(bound == ["In Progress", "Blocked", "Ready for Review", "Done…"])
    }
}
