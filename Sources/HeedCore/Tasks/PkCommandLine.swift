import Foundation

/// `heed pk …`: the app's pk adapter from a terminal. `scripts/e2e-pk.sh` drives it against real pk and a throwaway
/// vault; `PK_*` variables reach pk unchanged, so it sees what pk sees.
public enum PkCommandLine {
    public static let usage = """
    usage: heed pk [--python <path>] paths
           heed pk [--python <path>] list
           heed pk [--python <path>] new <title>
           heed pk [--python <path>] watch      (prints the sidebar whenever pk's tasks change; runs until killed)
    Without --python, [pk] python from config.toml.
    """

    public static func run(
        _ arguments: [String],
        write: @escaping @Sendable (String) -> Void = Self.print
    ) async -> Int32 {
        var args = arguments[...]
        var python: String?
        if args.first == "--python" {
            args.removeFirst()
            python = args.popFirst()
        }
        let source = (try? String(contentsOf: ConfigLoader.defaultFile(), encoding: .utf8)) ?? ""
        let configured = ConfigLoader.decode(source).config?.pkPython ?? HeedConfig.defaultPkPython
        let bridge = PkBridge.live(python: Paths.expand(python ?? configured))
        do {
            switch args.popFirst() {
            case "paths":
                let paths = try await bridge.paths()
                for (name, path) in [
                    ("vault", paths.vault), ("projects", paths.projects), ("kibanaMain", paths.kibanaMain),
                    ("kibanaWorktrees", paths.kibanaWorktrees), ("portsFile", paths.portsFile),
                    ("caddyfile", paths.caddyfile),
                ] {
                    write("\(name)\t\(path)")
                }
            case "list":
                for task in try await bridge.list().tasks {
                    write("\(task.status)\t\(task.title)\t\(task.port.map(String.init) ?? "-")")
                }
            case "new":
                let title = args.joined(separator: " ")
                guard !title.isEmpty else { return usageError() }
                try await write(bridge.new(title: title).notePath ?? "")
            case "watch":
                try await watch(bridge, write: write)
            default:
                return usageError()
            }
        } catch {
            FileHandle.standardError.write(Data("heed pk: \(error)\n".utf8))
            return 1
        }
        return 0
    }

    /// The sidebar as one line, for scripts: listed tasks in order, each with its Kibana port.
    public static func sidebar(_ tasks: [WorkTask]) -> String {
        "sidebar: " + TaskList(tasks).ordered.map { task in
            task.port.map { "\(task.title) [\($0)]" } ?? task.title
        }.joined(separator: " | ")
    }

    /// Runs `PkSync` as the app does, on a domain of its own, and prints the sidebar after the first list and each
    /// time it changes.
    private static func watch(_ bridge: PkBridge, write: @escaping @Sendable (String) -> Void) async throws {
        let state = WatchState(write: write)
        let sync = PkSync(
            bridge: bridge,
            tasks: { await state.tasks },
            apply: { await state.apply($0) },
            report: { FileHandle.standardError.write(Data("heed pk: \($0)\n".utf8)) }
        )
        guard await sync.start() != nil else { throw PkError(code: "not_started", message: "pk did not answer") }
        await sync.settled()
        await state.printSidebar()
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    private actor WatchState {
        var domain = Domain()
        var printed: String?
        let write: @Sendable (String) -> Void

        init(write: @escaping @Sendable (String) -> Void) { self.write = write }

        var tasks: [WorkTask] { domain.tasks }

        func apply(_ changes: [DomainChange]) {
            domain = domain.applying(changes)
            if printed != nil { printSidebar() }
        }

        func printSidebar() {
            let line = PkCommandLine.sidebar(domain.tasks)
            guard line != printed else { return }
            printed = line
            write(line)
        }
    }

    /// Unbuffered, so a script reading the output sees each line at once.
    public static let print: @Sendable (String) -> Void = { line in
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private static func usageError() -> Int32 {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        return 2
    }
}
