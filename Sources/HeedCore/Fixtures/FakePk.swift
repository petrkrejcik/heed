import Foundation

/// A pk that lives in memory, for fixtures, screenshots and tests: it answers bridge requests like pk does, NDJSON
/// records and all, from the tasks it was given. It never starts a process or touches a disk.
public actor FakePk {
    private var tasks: [PkTask]
    private let paths: PkPaths
    /// Every method called, in order, for tests.
    public private(set) var calls: [String] = []

    public init(tasks: [WorkTask], home: String = Fixtures.home) {
        paths = PkPaths(
            vault: "\(home)/notes", projects: "\(home)/notes/Projects", kibanaMain: "\(home)/www/kibana",
            kibanaWorktrees: "\(home)/www/kibana.worktrees", portsFile: "\(home)/.kbni-ports",
            caddyfile: "/opt/homebrew/etc/Caddyfile"
        )
        self.tasks = tasks.map { task in
            PkTask(
                id: task.id, title: task.title, status: task.status.rawValue, pinned: task.pinned, kind: task.kind,
                issue: task.issue, pr: task.pr, worktree: task.worktree, branch: task.branch, port: task.port,
                running: task.running, notePath: task.notePath, epic: task.epic, created: task.created
            )
        }
    }

    /// A bridge whose every request this answers.
    public nonisolated var bridge: PkBridge {
        PkBridge(python: "/fake/pk/python") { invocation in await self.respond(to: invocation) }
    }

    public func respond(to invocation: PkBridge.Invocation) -> ProcessResult {
        let request = (try? JSONSerialization.jsonObject(with: invocation.input)) as? [String: Any] ?? [:]
        let id = request["id"] as? String ?? "fake"
        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]
        calls.append(method)
        let started = #"{"version":1,"id":"\#(id)","type":"progress","stage":"started"}"#
        do {
            let data = try answer(method, params)
            let line = "{\"version\":1,\"id\":\"\(id)\",\"type\":\"result\",\"data\":\(String(decoding: data, as: UTF8.self))}"
            return ProcessResult(status: 0, stdout: started + "\n" + line + "\n", stderr: "")
        } catch {
            let error = error as? PkError ?? PkError(code: "internal_error", message: "\(error)")
            let body = try? JSONSerialization.data(withJSONObject: ["code": error.code, "message": error.message])
            let line = "{\"version\":1,\"id\":\"\(id)\",\"type\":\"error\",\"error\":\(String(decoding: body ?? Data(), as: UTF8.self))}"
            return ProcessResult(status: 1, stdout: started + "\n" + line + "\n", stderr: "")
        }
    }

    private func answer(_ method: String, _ params: [String: Any]) throws -> Data {
        let encoder = JSONEncoder()
        switch method {
        case "paths.get":
            return try encoder.encode(paths)
        case "task.list":
            return try encoder.encode(TaskListResult(tasks: tasks, warnings: []))
        case "task.get":
            return try encoder.encode(["task": tasks[index(params["id"])]])
        case "task.new":
            let title = (params["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { throw PkError(
                code: "invalid_params",
                message: "title must be a non-empty string"
            ) }
            let note = "\(paths.projects)/\(title).md"
            guard !tasks.contains(where: { $0.notePath == note }) else {
                throw PkError(code: "task_error", message: "Note already exists: \(note)")
            }
            let task = PkTask(id: NewTask.newID(), title: title, status: TaskStatus.inProgress.rawValue, notePath: note)
            tasks.append(task)
            return try encoder.encode(["task": task])
        case "task.status":
            let at = try index(params["id"])
            tasks[at].status = params["status"] as? String ?? tasks[at].status
            let removed = tasks[at].status == TaskStatus.done.rawValue && tasks[at].kind == "review"
                ? tasks[at].worktree : nil
            if removed != nil { tasks[at].worktree = nil }
            return try encoder.encode(PkStatusResult(task: tasks[at], removedWorktree: removed, blockers: []))
        case "task.pin":
            let at = try index(params["id"])
            tasks[at].pinned = params["pinned"] as? Bool ?? true
            return try encoder.encode(["task": tasks[at]])
        case "task.link":
            let at = try index(params["id"])
            let link = params["link"] as? String ?? ""
            if link.contains("/pull/") { tasks[at].pr = link } else { tasks[at].issue = link }
            return try encoder.encode(["task": tasks[at]])
        case "task.worktree.add":
            let at = try index(params["id"])
            guard tasks[at].worktree == nil else {
                throw PkError(code: "task_error", message: "\(tasks[at].title) already has a worktree")
            }
            let branch = Self.slug(tasks[at].title)
            tasks[at].branch = branch
            tasks[at].worktree = "\(paths.kibanaWorktrees)/\(branch)"
            return try encoder.encode(["task": tasks[at]])
        case "task.review.new":
            let number = params["number"] as? Int ?? 0
            let title = "Review PR \(number)"
            let branch = "review-\(number)"
            let task = PkTask(
                id: NewTask.newID(), title: title, status: TaskStatus.inProgress.rawValue, kind: "review",
                pr: PullRef(repo: Kibana.repo, number: number).url, worktree: "\(paths.kibanaWorktrees)/\(branch)",
                branch: branch, notePath: "\(paths.projects)/\(title).md"
            )
            tasks.append(task)
            return try encoder.encode(["task": task])
        case "task.pr.sync":
            return try encoder.encode(["linked": [PkTask]()])
        default:
            throw PkError(code: "method_not_found", message: "Unknown bridge method: \(method)")
        }
    }

    private struct TaskListResult: Encodable {
        var tasks: [PkTask]
        var warnings: [String]
    }

    private func index(_ reference: Any?) throws -> Int {
        let reference = reference as? String ?? ""
        guard let at = tasks.firstIndex(where: {
            $0.id == reference || $0.notePath == reference || $0.title.lowercased() == reference.lowercased()
        }) else { throw PkError(code: "task_error", message: "No task found for '\(reference)'") }
        return at
    }

    /// pk's branch rule, roughly: lower case, words joined by dashes.
    static func slug(_ title: String) -> String {
        let words = title.lowercased().split { !$0.isLetter && !$0.isNumber }
        return String(words.joined(separator: "-").prefix(63))
    }
}
