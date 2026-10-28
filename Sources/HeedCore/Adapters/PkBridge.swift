import Foundation

/// The paths pk works with, after its `PK_*` overrides. Heed asks pk for them rather than keeping its own copy, so a
/// run with the overrides set (the e2e script) never sees the real vault, Kibana checkout or ports file.
public struct PkPaths: Hashable, Sendable, Codable {
    public var vault: String
    public var projects: String
    public var kibanaMain: String
    public var kibanaWorktrees: String
    public var portsFile: String
    public var caddyfile: String

    public init(
        vault: String, projects: String, kibanaMain: String, kibanaWorktrees: String, portsFile: String,
        caddyfile: String
    ) {
        self.vault = vault
        self.projects = projects
        self.kibanaMain = kibanaMain
        self.kibanaWorktrees = kibanaWorktrees
        self.portsFile = portsFile
        self.caddyfile = caddyfile
    }
}

/// A task as pk's bridge sends it (pk's `docs/bridge-v1.md`, "A task has this shape").
public struct PkTask: Hashable, Sendable, Codable {
    /// The note's `task_id`; pk writes one on the first read, so it is missing only when that write failed.
    public var id: String?
    public var title: String
    public var status: String
    public var pinned: Bool
    public var kind: String?
    public var issue: String?
    public var pr: String?
    public var worktree: String?
    public var branch: String?
    public var port: Int?
    public var running: Bool
    /// The address `pk kbn` would open for the task's checkout; nil until it has a port.
    public var kibanaUrl: String?
    public var notePath: String?
    public var epic: String?
    public var created: String?

    public init(
        id: String?, title: String, status: String, pinned: Bool = false, kind: String? = nil, issue: String? = nil,
        pr: String? = nil, worktree: String? = nil, branch: String? = nil, port: Int? = nil, running: Bool = false,
        kibanaUrl: String? = nil, notePath: String? = nil, epic: String? = nil, created: String? = nil
    ) {
        self.kibanaUrl = kibanaUrl
        self.id = id
        self.title = title
        self.status = status
        self.pinned = pinned
        self.kind = kind
        self.issue = issue
        self.pr = pr
        self.worktree = worktree
        self.branch = branch
        self.port = port
        self.running = running
        self.notePath = notePath
        self.epic = epic
        self.created = created
    }
}

/// What `task.status` did: the task as written, and for a review set to Done, its worktree removed or why not.
public struct PkStatusResult: Hashable, Sendable, Codable {
    public var task: PkTask
    public var removedWorktree: String?
    public var blockers: [String]
}

/// What `task.pr.sync` did: the tasks that got a PR, as written, and the ids of those that also moved to Ready for
/// Review (their PR was already open for review).
public struct PkPullSync: Hashable, Sendable, Codable {
    public var linked: [PkTask]
    public var ready: [String]

    public init(linked: [PkTask], ready: [String] = []) {
        self.linked = linked
        self.ready = ready
    }

    // An older pk sends no `ready`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        linked = try container.decode([PkTask].self, forKey: .linked)
        ready = try container.decodeIfPresent([String].self, forKey: .ready) ?? []
    }

    private enum CodingKeys: String, CodingKey { case linked, ready }
}

/// What `task.pr.ready` did: the task as it is now, whether it moved, and why (`PR #12 is open`, `PR #12 is a draft`).
public struct PkReadyResult: Hashable, Sendable, Codable {
    public var task: PkTask
    public var moved: Bool
    public var detail: String

    public init(task: PkTask, moved: Bool, detail: String) {
        self.task = task
        self.moved = moved
        self.detail = detail
    }
}

/// pk refused (its `error` record), or could not be run at all.
public struct PkError: Error, Equatable, Sendable, CustomStringConvertible {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// pk did not answer: it could not start, or ended without a result.
    public static let notRunCodes: Set<String> = ["not_started", "no_result"]
    public var isAnswer: Bool { !Self.notRunCodes.contains(code) }

    public var description: String { message }
}

/// pk's JSON bridge: one `<python> -m pk.bridge` process per request, run through `ProcessRunner` (async, never on the
/// main actor), one request on its stdin, NDJSON progress, result and error records on its stdout.
public struct PkBridge: Sendable {
    public struct Invocation: Sendable, Equatable {
        public var executable: String
        public var arguments: [String]
        /// The request, one JSON object.
        public var input: Data
        public var timeout: Duration
    }

    public typealias Runner = @Sendable (Invocation) async throws -> ProcessResult

    /// `[pk] python`: pk's virtualenv python, which has pk installed.
    public let python: String
    private let run: Runner

    public init(python: String, run: @escaping Runner) {
        self.python = python
        self.run = run
    }

    /// The real pk. `environment` supplies what the process gets on top of Heed's own (the app passes the detected
    /// PATH, so pk finds git and gh; the `heed` command line passes nothing and keeps the shell's).
    public static func live(
        python: String, environment: @escaping @Sendable () async -> [String: String]? = { nil }
    ) -> PkBridge {
        PkBridge(python: python) { invocation in
            try await ProcessRunner.run(
                invocation.executable, invocation.arguments, environment: environment(),
                timeout: invocation.timeout, stdin: invocation.input
            )
        }
    }

    /// The command line that runs pk itself (`pk kbn bootstrap`) with the same python, for terminal tabs.
    public func commandLine(_ arguments: [String]) -> String {
        ([python, "-m", "pk"] + arguments).map(ShellQuote.quote).joined(separator: " ")
    }

    // MARK: Methods

    public func paths() async throws -> PkPaths {
        try await call("paths.get", NoParams())
    }

    public struct TaskList: Sendable, Decodable {
        public var tasks: [PkTask]
        public var warnings: [String]

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tasks = try container.decode([PkTask].self, forKey: .tasks)
            warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        }

        private enum CodingKeys: String, CodingKey { case tasks, warnings }
    }

    /// Every task, whatever its status: the sidebar picks what it shows, and `:task` finds To Do ones.
    public func list() async throws -> TaskList {
        try await call("task.list", NoParams())
    }

    /// By id, note path or exact title.
    public func get(_ reference: String) async throws -> PkTask {
        try await call("task.get", ["id": reference], as: TaskResult.self).task
    }

    public func new(title: String, context: String? = nil) async throws -> PkTask {
        struct Params: Encodable, Sendable {
            var title: String
            var context: String?
        }
        let context = context.flatMap { $0.isEmpty ? nil : $0 }
        return try await call("task.new", Params(title: title, context: context), as: TaskResult.self).task
    }

    /// A review set to Done also loses its worktree, when nothing would be lost; that can take a while.
    public func setStatus(_ id: String, _ status: TaskStatus) async throws -> PkStatusResult {
        try await call("task.status", ["id": id, "status": status.rawValue], timeout: .seconds(300))
    }

    public func pin(_ id: String, _ pinned: Bool) async throws -> PkTask {
        struct Params: Encodable, Sendable {
            var id: String
            var pinned: Bool
        }
        return try await call("task.pin", Params(id: id, pinned: pinned), as: TaskResult.self).task
    }

    /// An `elastic/kibana` issue or PR URL.
    public func link(_ id: String, _ url: String) async throws -> PkTask {
        try await call("task.link", ["id": id, "link": url], as: TaskResult.self).task
    }

    /// Creates the worktree (not bootstrapped) and records it on the task. Checking out Kibana takes a while.
    public func addWorktree(_ id: String) async throws -> PkTask {
        try await call("task.worktree.add", ["id": id], timeout: .seconds(900), as: TaskResult.self).task
    }

    /// The task "Review PR <n> - <title>", with the PR imported into a worktree.
    public func newReview(_ number: Int) async throws -> PkTask {
        try await call("task.review.new", ["number": number], timeout: .seconds(900), as: TaskResult.self).task
    }

    /// Links the PR opened from the task's branch, if there is one. One already open for review also moves the task
    /// from In Progress to Ready for Review.
    public func syncPRs(_ id: String) async throws -> PkPullSync {
        try await call("task.pr.sync", ["id": id])
    }

    /// In Progress to Ready for Review when pk finds the task's PR open and not a draft. Call it when the PR changed
    /// (newly linked, out of draft): pk acts on the PR as it is now.
    public func markReady(_ id: String) async throws -> PkReadyResult {
        try await call("task.pr.ready", ["id": id])
    }

    // MARK: Protocol

    private struct NoParams: Encodable, Sendable {}

    private struct TaskResult: Decodable {
        var task: PkTask
    }

    private struct Request<Params: Encodable>: Encodable {
        var version = 1
        var id: String
        var method: String
        var params: Params
    }

    /// Sends one request and decodes its result.
    public func call<Result: Decodable>(
        _ method: String, _ params: some Encodable & Sendable, timeout: Duration = .seconds(60),
        as _: Result.Type = Result.self
    ) async throws -> Result {
        let input = try JSONEncoder().encode(Request(id: "heed-\(UUID().uuidString)", method: method, params: params))
        let output: ProcessResult
        do {
            output = try await run(Invocation(
                executable: python, arguments: ["-m", "pk.bridge"], input: input, timeout: timeout
            ))
        } catch {
            throw PkError(code: "not_started", message: "pk: \(error) (check [pk] python in config.toml)")
        }
        let data = try Self.result(of: output)
        do {
            return try JSONDecoder().decode(Result.self, from: data)
        } catch {
            throw PkError(code: "bad_result", message: "pk \(method): unexpected result (\(error))")
        }
    }

    /// One record of pk's output.
    public enum Record: Equatable, Sendable {
        case progress(stage: String, message: String?)
        /// The `data` of the result record, as JSON.
        case result(Data)
        case error(PkError)
    }

    /// The records in pk's stdout, in order. Lines that are not records are skipped: stdout carries nothing else by
    /// contract, but a stray print must not lose the result.
    public static func records(_ stdout: String) -> [Record] {
        stdout.split(whereSeparator: \.isNewline).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                return nil
            }
            switch object["type"] as? String {
            case "progress":
                return .progress(stage: object["stage"] as? String ?? "", message: object["message"] as? String)
            case "result":
                let data = object["data"].flatMap {
                    try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed])
                }
                return .result(data ?? Data("null".utf8))
            case "error":
                let error = object["error"] as? [String: Any] ?? [:]
                return .error(PkError(
                    code: error["code"] as? String ?? "internal_error",
                    message: error["message"] as? String ?? "pk failed"
                ))
            default:
                return nil
            }
        }
    }

    /// The result's data, or pk's error. Without either, what pk printed on stderr says why.
    public static func result(of output: ProcessResult) throws -> Data {
        for record in records(output.stdout).reversed() {
            switch record {
            case let .result(data): return data
            case let .error(error): throw error
            case .progress: continue
            }
        }
        let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last
            .map(String.init) ?? "exit \(output.status)"
        throw PkError(code: "no_result", message: "pk ended without a result: \(detail)")
    }
}
