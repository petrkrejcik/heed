import Foundation
@testable import HeedCore
import Testing

/// A runner that answers every request with `stdout` (pk's NDJSON, recorded) and keeps what it was asked.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var invocations: [PkBridge.Invocation] = []
    var last: PkBridge.Invocation? { lock.withLock { invocations.last } }

    func bridge(stdout: String, stderr: String = "", status: Int32 = 0) -> PkBridge {
        PkBridge(python: "/venv/bin/python") { invocation in
            self.lock.withLock { self.invocations.append(invocation) }
            return ProcessResult(status: status, stdout: stdout, stderr: stderr)
        }
    }

    /// The last request as JSON.
    var request: [String: Any] {
        guard let input = last?.input else { return [:] }
        return (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
    }

    var params: [String: Any] { request["params"] as? [String: Any] ?? [:] }
}

/// What `python -m pk.bridge` printed for a `task.list` (one task in a worktree, one in the main checkout).
private let listOutput = """
{"version":1,"id":"heed-1","type":"progress","stage":"started","message":"Listing tasks"}
{"version":1,"id":"heed-1","type":"result","data":{"tasks":[{"id":"t-1","title":"Fix upload","status":"In Progress",\
"pinned":true,"kind":null,"issue":"https://github.com/elastic/kibana/issues/1","pr":null,\
"worktree":"/w/fix-upload","branch":"fix-upload","port":5602,"running":false,\
"kibanaUrl":"http://fix-upload.localhost/app/agent_builder","notePath":"/v/Projects/Fix upload.md",\
"epic":null,"created":"2026-10-20"},{"id":"t-2","title":"Plan","status":"To Do","pinned":false,"kind":null,\
"issue":null,"pr":null,"worktree":null,"branch":null,"port":5601,"running":true,"notePath":"/v/Projects/Plan.md",\
"epic":"Agent Builder","created":null}],"warnings":["Projects/Odd.md: no status"]}}

"""

private let taskOutput = """
{"version":1,"id":"heed-1","type":"result","data":{"task":{"id":"t-9","title":"New one","status":"In Progress",\
"pinned":false,"worktree":null,"branch":null,"port":5601,"running":false,"notePath":"/v/Projects/New one.md"}}}

"""

struct PkBridgeTests {
    @Test func sendsOneRequestAndDecodesTheTasks() async throws {
        let recorder = Recorder()
        let list = try await recorder.bridge(stdout: listOutput).list()
        let invocation = try #require(recorder.last)
        #expect(invocation.executable == "/venv/bin/python")
        #expect(invocation.arguments == ["-m", "pk.bridge"])
        #expect(recorder.request["version"] as? Int == 1)
        #expect(recorder.request["method"] as? String == "task.list")
        #expect((recorder.request["id"] as? String)?.hasPrefix("heed-") == true)
        #expect(recorder.params.isEmpty)
        #expect(list.tasks.map(\.id) == ["t-1", "t-2"])
        #expect(list.tasks[0].pinned && list.tasks[0].port == 5602 && list.tasks[0].worktree == "/w/fix-upload")
        #expect(list.tasks[1].running && list.tasks[1].epic == "Agent Builder" && list.tasks[1].created == nil)
        #expect(list.tasks[0].kibanaUrl == "http://fix-upload.localhost/app/agent_builder")
        // An older pk sends no kibanaUrl.
        #expect(list.tasks[1].kibanaUrl == nil)
        #expect(WorkTask(list.tasks[0], keeping: nil)?.kibanaURL == "http://fix-upload.localhost/app/agent_builder")
        #expect(list.warnings == ["Projects/Odd.md: no status"])
    }

    @Test func methodsSendTheirParams() async throws {
        let recorder = Recorder()
        let bridge = recorder.bridge(stdout: taskOutput)
        _ = try await bridge.new(title: "New one", context: "")
        #expect(recorder.request["method"] as? String == "task.new")
        #expect(recorder.params["title"] as? String == "New one")
        #expect(recorder.params["context"] == nil)
        _ = try await bridge.pin("t-9", false)
        #expect(recorder.params["pinned"] as? Bool == false)
        _ = try await bridge.link("t-9", "https://github.com/elastic/kibana/pull/7")
        #expect(recorder.params["link"] as? String == "https://github.com/elastic/kibana/pull/7")
        _ = try await bridge.addWorktree("t-9")
        #expect(recorder.request["method"] as? String == "task.worktree.add")
        #expect(recorder.last?.timeout == .seconds(900))
        _ = try await bridge.newReview(42)
        #expect(recorder.params["number"] as? Int == 42)
    }

    @Test func statusSendsTheNoteSpelling() async throws {
        let recorder = Recorder()
        let output = """
        {"version":1,"id":"x","type":"result","data":{"task":{"id":"t-1","title":"R","status":"Done","pinned":false,\
        "port":null,"running":false},"removedWorktree":null,"blockers":["uncommitted changes"]}}
        """
        let result = try await recorder.bridge(stdout: output).setStatus("t-1", .done)
        #expect(recorder.params["status"] as? String == "Done")
        #expect(recorder.last?.timeout == .seconds(300))
        #expect(result.task.status == "Done")
        #expect(result.blockers == ["uncommitted changes"])
    }

    @Test func pkRefusingIsAnAnswer() async {
        let output = """
        {"version":1,"id":"x","type":"progress","stage":"started"}
        {"version":1,"id":"x","type":"error","error":{"code":"task_error","message":"No task found for 'nope'"}}
        """
        await #expect(throws: PkError(code: "task_error", message: "No task found for 'nope'")) {
            try await Recorder().bridge(stdout: output, status: 1).get("nope")
        }
        #expect(PkError(code: "task_error", message: "").isAnswer)
    }

    @Test func noResultSaysWhatPkPrinted() async throws {
        let bridge = Recorder().bridge(
            stdout: "", stderr: "Traceback (most recent call last):\nModuleNotFoundError: No module named 'pk'\n",
            status: 1
        )
        do {
            _ = try await bridge.list()
            Issue.record("expected an error")
        } catch let error as PkError {
            #expect(error.code == "no_result")
            #expect(error.message.hasSuffix("ModuleNotFoundError: No module named 'pk'"))
            #expect(!error.isAnswer)
        }
    }

    @Test func aPythonThatCannotStartPointsAtTheConfig() async throws {
        struct Missing: Error {}
        let bridge = PkBridge(python: "/nope/python") { _ in throw Missing() }
        do {
            _ = try await bridge.paths()
            Issue.record("expected an error")
        } catch let error as PkError {
            #expect(error.code == "not_started")
            #expect(error.message.contains("[pk] python"))
        }
    }

    @Test func strayLinesAreSkipped() {
        let records = PkBridge.records("""
        hello from a print
        {"version":1,"id":"x","type":"progress","stage":"git","message":"fetching"}
        {"version":1,"id":"x","type":"result","data":{"ok":true}}
        """)
        #expect(records.count == 2)
        #expect(records.first == .progress(stage: "git", message: "fetching"))
    }

    @Test func theCommandLineUsesTheSamePython() {
        let bridge = PkBridge(python: "/My Venv/bin/python") { _ in ProcessResult(status: 0, stdout: "", stderr: "") }
        #expect(bridge.commandLine(["kbn", "bootstrap"]) == "'/My Venv/bin/python' -m pk kbn bootstrap")
    }
}

private func pkTask(
    _ id: String?, title: String? = nil, status: TaskStatus = .inProgress, port: Int? = nil, running: Bool = false,
    created: String? = nil
) -> PkTask {
    PkTask(
        id: id, title: title ?? id ?? "untitled", status: status.rawValue, port: port, running: running,
        notePath: "/v/Projects/\(id ?? "x").md", created: created
    )
}

struct TaskSyncTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func aListUpsertsWhatChangedAndRemovesWhatWent() throws {
        var kept = try #require(WorkTask(pkTask("a"), keeping: nil, now: now))
        kept.record("started", at: now)
        let same = try #require(WorkTask(pkTask("b"), keeping: nil, now: now))
        let gone = try #require(WorkTask(pkTask("c"), keeping: nil, now: now))
        let changes = TaskSync.reconcile(
            [pkTask("a", status: .blocked), pkTask("b"), pkTask("d"), pkTask(nil)], into: [kept, same, gone], now: now
        )
        #expect(changes.count == 3)
        guard case let .taskUpserted(blocked) = changes[0], case let .taskUpserted(new) = changes[1],
              case .taskRemoved("c") = changes[2]
        else {
            Issue.record("unexpected changes \(changes)")
            return
        }
        #expect(blocked.status == .blocked)
        #expect(blocked.timeline == kept.timeline)
        #expect(blocked.lastActivity == kept.lastActivity)
        #expect(new.id == "d")
    }

    @Test func aNewTaskIsAsOldAsItsNote() throws {
        let task = try #require(WorkTask(pkTask("a", created: "2026-10-20"), keeping: nil, now: now))
        #expect(task.lastActivity == TaskSync.day("2026-10-20"))
        #expect(task.lastActivity < now)
        #expect(WorkTask(pkTask("b"), keeping: nil, now: now)?.lastActivity == now)
        #expect(WorkTask(pkTask(nil), keeping: nil, now: now) == nil)
    }

    @Test func oneTaskUpdatesOnlyWhenPkChangedIt() throws {
        let task = try #require(WorkTask(pkTask("a", port: 5602), keeping: nil, now: now))
        #expect(TaskSync.update(pkTask("a", port: 5602), in: [task], now: now) == nil)
        guard case let .taskUpserted(moved)? = TaskSync.update(pkTask("a", port: 5603), in: [task], now: now)
        else {
            Issue.record("expected an upsert")
            return
        }
        #expect(moved.port == 5603)
    }

    @Test func theProbeChangesOnlyProbedPorts() throws {
        let up = try #require(WorkTask(pkTask("up", port: 5602), keeping: nil))
        let down = try #require(WorkTask(pkTask("down", port: 5603, running: true), keeping: nil))
        let other = try #require(WorkTask(pkTask("other", port: 5604, running: true), keeping: nil))
        let changes = TaskSync.running(listening: [5602], probed: [5602, 5603], in: [up, down, other])
        let running = changes.compactMap { change -> String? in
            guard case let .taskUpserted(task) = change else { return nil }
            return "\(task.id) \(task.running)"
        }
        #expect(running == ["up true", "down false"])
    }

    @Test func fileEventsPickNotesOrAFullList() {
        let note = "/v/Projects/A.md"
        #expect(TaskSync.notesToRead([FileEvent(path: note), FileEvent(path: note)]) == [note])
        #expect(TaskSync.notesToRead([
            FileEvent(path: "/v/Projects/.obsidian/workspace.md"), FileEvent(path: "/v/Projects/pic.png"),
            FileEvent(path: "/v/Projects/Sub", isDirectory: true),
        ]) == [])
        #expect(TaskSync.notesToRead([FileEvent(path: "/v/Projects/Sub", isDirectory: true, structural: true)]) == nil)
        let many = (1 ... 6).map { FileEvent(path: "/v/Projects/\($0).md") }
        #expect(TaskSync.notesToRead(many) == nil)
    }
}

struct TaskStatusTests {
    @Test func statusesAreNamedLooselyOnTheCommandLine() {
        #expect(TaskStatus.named("done") == .done)
        #expect(TaskStatus.named("in-progress") == .inProgress)
        #expect(TaskStatus.named("In Progress") == .inProgress)
        #expect(TaskStatus.named("wip") == .inProgress)
        #expect(TaskStatus.named("ready") == .readyForReview)
        #expect(TaskStatus.named("Ready for Review") == .readyForReview)
        #expect(TaskStatus.named("todo") == .toDo)
        #expect(TaskStatus.named("soon") == nil)
        #expect(TaskStatus.done.endsTask && TaskStatus.dropped.endsTask && !TaskStatus.readyForReview.endsTask)
    }
}

struct PkConfigTests {
    @Test func pkPythonComesFromConfig() throws {
        #expect(ConfigLoader.decode(ConfigLoader.defaultSource).config?.pkPython == HeedConfig.defaultPkPython)
        let (decoded, problems) = ConfigLoader.decode("[pk]\npython = \"/opt/pk/bin/python\"")
        #expect(problems.isEmpty)
        #expect(try #require(decoded).pkPython == "/opt/pk/bin/python")
        let (empty, emptyProblems) = ConfigLoader.decode("[pk]\npython = \"\"")
        #expect(try #require(empty).pkPython == HeedConfig.defaultPkPython)
        #expect(emptyProblems.map(\.path) == ["pk.python"])
    }
}

struct MovingAgentTests {
    @Test func theAgentMovesAndTheSetupTabsFollow() throws {
        let agent = PaneTab(id: "agent-tab", title: "agent", pane: PaneSpec(
            id: "agent", role: .agent, title: "claude", directory: "/k"
        ))
        var layout = TaskLayout(tabs: [agent])
        layout.add(PaneTab(title: "kibana", pane: pane("kibana")), show: true)
        let added = NewTask.setupTabs(worktree: "/w/a", bootstrap: "pk kbn bootstrap", settings: .default)
        let moved = try #require(NewTask.movingAgent("agent", to: "/w/a", in: layout, adding: added))
        #expect(moved.groups.map { $0.tabs.map(\.title) } == [["agent"], ["kibana", "bootstrap"]])
        #expect(moved.focusedPane?.id == "agent")
        #expect(moved.pane("agent")?.directory == "/w/a")
        #expect(moved.pane("kibana")?.directory == "/k")
        // The bootstrap's progress shows in the work pane.
        #expect(moved.groups[1].active?.title == "bootstrap")
        #expect(NewTask.movingAgent("gone", to: "/w/a", in: layout, adding: added) == nil)
        #expect(NewTask.moveCommand(to: "/w/a") == "/cd /w/a")
    }

    private func pane(_ id: String) -> PaneSpec { PaneSpec(id: id, role: .shell, title: id, directory: "/k") }
}

struct ReviewNumberTests {
    @Test func aNumberOrAKibanaPRURL() {
        #expect(NewTask.reviewNumber("300162") == 300_162)
        #expect(NewTask.reviewNumber("#300162") == 300_162)
        #expect(NewTask.reviewNumber(" https://github.com/elastic/kibana/pull/300162 ") == 300_162)
        #expect(NewTask.reviewNumber("https://github.com/elastic/kibana/pull/300162/files?w=1") == 300_162)
        #expect(NewTask.reviewNumber("https://github.com/elastic/elasticsearch/pull/1") == nil)
        #expect(NewTask.reviewNumber("https://github.com/elastic/kibana/issues/300162") == nil)
        #expect(NewTask.reviewNumber("0") == nil)
        #expect(NewTask.reviewNumber("soon") == nil)
    }
}

struct WorktreeTabsTests {
    @Test func bootstrapThenPinnedCommandsThenTheAgent() throws {
        var settings = WorkSettings.default
        settings.commands = [PinnedCommand(name: "jest", command: "yarn test:jest")]
        let prompt = NewTask.handoverPrompt(note: "/v/Projects/A.md")
        let made = NewTask.worktreeTabs(
            worktree: "/w/a", prompt: prompt, bootstrap: "pk kbn bootstrap", settings: settings, integration: nil
        )
        #expect(made.tabs.map(\.title) == ["bootstrap", "jest", "agent"])
        let panes = made.tabs.map(\.pane)
        #expect(panes.allSatisfy { $0.directory == "/w/a" && $0.command != nil })
        #expect(panes[0].command == "pk kbn bootstrap")
        #expect(panes[1].role == .command)
        #expect(panes[1].command?.hasPrefix("yarn test:jest; ") == true)
        #expect(panes[2].role == .agent)
        #expect(panes[2].command?.contains("Read the task note at /v/Projects/A.md and continue.") == true)
        #expect(made.agent?.pane == panes[2].id)
    }
}

/// The domain a test sync writes into.
private actor Box {
    var domain = Domain()
    var reports: [String] = []
    func apply(_ changes: [DomainChange]) { domain = domain.applying(changes) }
    func report(_ text: String) { reports.append(text) }
}

struct FakePkTests {
    @Test func answersLikePk() async throws {
        let fake = FakePk(tasks: [WorkTask(id: "a", title: "Review it", kind: "review", worktree: "/w/r")])
        let bridge = fake.bridge
        #expect(try await bridge.paths().projects == "\(Fixtures.home)/notes/Projects")
        let created = try await bridge.new(title: "Write docs")
        #expect(created.notePath == "\(Fixtures.home)/notes/Projects/Write docs.md")
        await #expect(throws: PkError.self) { try await bridge.new(title: "Write docs") }
        let id = try #require(created.id)
        let added = try await bridge.addWorktree(id)
        #expect(added.branch == "write-docs")
        let done = try await bridge.setStatus("a", .done)
        #expect(done.removedWorktree == "/w/r" && done.task.worktree == nil)
        #expect(try await bridge.list().tasks.map(\.title) == ["Review it", "Write docs"])
        await #expect(throws: PkError(code: "method_not_found", message: "Unknown bridge method: task.nope")) {
            try await bridge.call("task.nope", [String: String](), as: [String: String].self)
        }
        #expect(await fake.calls.first == "paths.get")
    }

    @Test func theSidebarLineListsWhatTheSidebarShows() {
        let tasks = [
            WorkTask(id: "a", title: "A", pinned: true, port: 5602),
            WorkTask(id: "b", title: "B", status: .toDo),
            WorkTask(id: "c", title: "C", lastActivity: Date(timeIntervalSince1970: 0)),
        ]
        #expect(PkCommandLine.sidebar(tasks) == "sidebar: A [5602] | C")
    }
}

struct PkSyncTests {
    @Test func startListsAndChangedNotesAreReadOneByOne() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("heed-pk-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(home)/notes/Projects", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fake = FakePk(tasks: [WorkTask(id: "a", title: "A", notePath: "\(home)/notes/Projects/A.md")], home: home)
        let box = Box()
        let sync = PkSync(
            bridge: fake.bridge, tasks: { await box.domain.tasks }, apply: { await box.apply($0) },
            report: { await box.report($0) }
        )
        let paths = try #require(await sync.start())
        #expect(paths.portsFile == "\(home)/.kbni-ports")
        await sync.settled()
        #expect(await box.domain.tasks.map(\.id) == ["a"])

        let created = try await fake.bridge.new(title: "B")
        let note = try #require(created.notePath)
        await sync.changed(.notes([FileEvent(path: note)]))
        await sync.settled()
        #expect(await box.domain.tasks.map(\.title).sorted() == ["A", "B"])
        #expect(await fake.calls.suffix(2) == ["task.new", "task.get"])

        await sync.changed(.notes([FileEvent(path: "\(home)/notes/Projects/Not a task.md")]))
        await sync.settled()
        #expect(await fake.calls.last == "task.get")

        await sync.changed(.ports)
        await sync.refresh()
        #expect(await fake.calls.suffix(2) == ["task.list", "task.list"])
        #expect(await box.reports.isEmpty)
        await sync.stop()
    }
}

struct PortProbeTests {
    @Test func aListeningPortAnswersAndAClosedOneDoesNot() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var open = true
        defer { if open { close(fd) } }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(fd, generic, length) == 0 && listen(fd, 1) == 0 && getsockname(fd, generic, &length) == 0
            }
        }
        try #require(bound)
        let port = Int(UInt16(bigEndian: address.sin_port))
        #expect(PortProbe.isListening(port))
        close(fd)
        open = false
        #expect(!PortProbe.isListening(port))
    }
}
