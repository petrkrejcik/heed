import Foundation

/// Everything `~/.config/heed/config.toml` says, as domain values. The agent is `[agents.claude]`, key bindings are
/// `[keys.<mode or view>]` tables of notation = command, pinned commands are `[commands]`. Sections this build no
/// longer has are ignored.
public struct HeedConfig: Equatable, Sendable {
    public var work: WorkSettings
    public var insertEscape: String
    /// The system-wide shortcut that brings Heed to the front; "" turns it off.
    public var globalActivate = "<C-M-h>"
    /// `[ui]`: Heed outside its window.
    public var showMenuBarItem = true
    public var showDockState = true
    /// `[keys.normal]`, `[keys.visual]`, ...: overrides laid over the defaults.
    public var keys: [Mode: [(String, String)]]
    /// `[keys.tasks]`, `[keys.inbox]`, ...: per-view overrides.
    public var scopedKeys: [String: [(String, String)]]
    public var githubPollSeconds: Int
    public var tools = ToolSettings()
    /// `[pk] python`: the python of pk's virtualenv; Heed runs `<python> -m pk.bridge` with it.
    public var pkPython = HeedConfig.defaultPkPython

    public static let defaultPkPython = "~/www/pk/.venv/bin/python"

    public static let `default` = HeedConfig(
        work: .default, insertEscape: DefaultKeys.insertEscape, keys: [:], scopedKeys: [:], githubPollSeconds: 60
    )

    public static func == (lhs: HeedConfig, rhs: HeedConfig) -> Bool {
        func flat(_ table: [Mode: [(String, String)]]) -> [String] {
            table.sorted { $0.key.rawValue < $1.key.rawValue }
                .flatMap { mode, pairs in pairs.map { "\(mode):\($0)=\($1)" } }
        }
        func flat(_ table: [String: [(String, String)]]) -> [String] {
            table.sorted { $0.key < $1.key }.flatMap { scope, pairs in pairs.map { "\(scope):\($0)=\($1)" } }
        }
        let same = [
            lhs.work == rhs.work,
            lhs.insertEscape == rhs.insertEscape,
            lhs.globalActivate == rhs.globalActivate,
            lhs.showMenuBarItem == rhs.showMenuBarItem,
            lhs.showDockState == rhs.showDockState,
            flat(lhs.keys) == flat(rhs.keys),
            flat(lhs.scopedKeys) == flat(rhs.scopedKeys),
            lhs.githubPollSeconds == rhs.githubPollSeconds,
            lhs.tools == rhs.tools,
            lhs.pkPython == rhs.pkPython,
        ]
        return !same.contains(false)
    }

    /// The keymaps this config asks for, with problems reported per entry.
    public func keymaps() -> (keymaps: [Mode: Keymap], scoped: [String: Keymap], problems: [Keymaps.Problem]) {
        Keymaps.build(overrides: keys, scopedOverrides: scopedKeys, insertEscape: insertEscape)
    }
}

public struct ConfigProblem: Equatable, Sendable, CustomStringConvertible {
    public let path: String
    public let message: String
    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    public var description: String { path.isEmpty ? message : "\(path): \(message)" }
}

public enum ConfigLoader {
    /// `~/.config/heed/config.toml` (or `$XDG_CONFIG_HOME/heed/config.toml`).
    public static func defaultFile() -> URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("heed/config.toml")
    }

    /// Parses and decodes. A syntax error returns no config (the caller keeps the last good one); a value that does
    /// not fit is reported and its default kept, so one typo never disables the rest.
    public static func decode(_ source: String) -> (config: HeedConfig?, problems: [ConfigProblem]) {
        let document: TOMLDocument
        do {
            document = try TOMLDocument(source)
        } catch {
            return (nil, [ConfigProblem(path: "", message: error.description)])
        }
        var problems: [ConfigProblem] = []
        var config = HeedConfig.default
        let root = document.root

        func string(_ path: [String]) -> String? {
            guard let value = root.value(at: path) else { return nil }
            guard let text = value.string else {
                problems.append(ConfigProblem(path: path.joined(separator: "."), message: "expected a string"))
                return nil
            }
            return text
        }
        func integer(_ path: [String], range: ClosedRange<Int>) -> Int? {
            guard let value = root.value(at: path) else { return nil }
            guard let number = value.integer, range.contains(number) else {
                problems.append(ConfigProblem(
                    path: path.joined(separator: "."),
                    message: "expected a number from \(range.lowerBound) to \(range.upperBound)"
                ))
                return nil
            }
            return number
        }
        func bool(_ path: [String]) -> Bool? {
            guard let value = root.value(at: path) else { return nil }
            guard let flag = value.bool else {
                problems.append(ConfigProblem(path: path.joined(separator: "."), message: "expected true or false"))
                return nil
            }
            return flag
        }
        func strings(_ path: [String]) -> [String]? {
            guard let value = root.value(at: path) else { return nil }
            guard let items = value.array?.compactMap(\.string), items.count == value.array?.count else {
                problems.append(ConfigProblem(path: path.joined(separator: "."), message: "expected a list of strings"))
                return nil
            }
            return items
        }
        func pairs(_ path: [String]) -> [(String, String)] {
            guard let table = root.value(at: path)?.table else { return [] }
            return table.keys.compactMap { key in
                guard let text = table[key]?.string else {
                    problems.append(ConfigProblem(
                        path: (path + [key]).joined(separator: "."),
                        message: "expected a string"
                    ))
                    return nil
                }
                return (key, text)
            }
        }

        // [sessions]
        if let policy = string(["sessions", "resume_on_launch"]) {
            if let parsed = ResumePolicy(rawValue: policy) {
                config.work.resumeOnLaunch = parsed
            } else {
                problems.append(ConfigProblem(
                    path: "sessions.resume_on_launch",
                    message: "expected ask, always or never"
                ))
            }
        }
        if let text = string(["sessions", "continue_prompt"]) { config.work.continuePrompt = text }
        if let flag = bool(["sessions", "shell_split"]) { config.work.shellSplit = flag }
        if let text = string(["sessions", "persist"]) {
            if let persist = PanePersistence(rawValue: text.lowercased()) {
                config.work.persist = persist
            } else {
                problems.append(ConfigProblem(path: "sessions.persist", message: "expected auto, zmx or none"))
            }
        }
        // [github]
        if let seconds = integer(["github", "poll_seconds"], range: 15 ... 3600) { config.githubPollSeconds = seconds }
        // [tools]
        if let git = string(["tools", "git"]) { config.tools.git = git }
        if let gh = string(["tools", "gh"]) { config.tools.gh = gh }
        if let zmx = string(["tools", "zmx"]) { config.tools.zmx = zmx }
        if let path = strings(["tools", "path"]) { config.tools.path = path }
        // [pk]
        if let python = string(["pk", "python"]) {
            if python.isEmpty {
                problems.append(ConfigProblem(path: "pk.python", message: "expected the path of pk's python"))
            } else {
                config.pkPython = python
            }
        }
        // [commands]
        config.work.commands = pairs(["commands"]).map { PinnedCommand(name: $0.0, command: $0.1) }

        // [agents.claude], field by field. Other agents run in a plain terminal tab, so other tables are ignored.
        for (index, base) in config.work.agents.enumerated() {
            let name = base.name
            guard let table = root.value(at: ["agents", name]) else { continue }
            guard table.table != nil else {
                problems.append(ConfigProblem(path: "agents.\(name)", message: "expected a table"))
                continue
            }
            var agent = base
            if let command = string(["agents", name, "command"]) { agent.command = command }
            if let delivery = string(["agents", name, "prompt"]) {
                if let parsed = PromptDelivery(rawValue: delivery) {
                    agent.prompt = parsed
                } else {
                    problems.append(ConfigProblem(
                        path: "agents.\(name).prompt", message: "expected argument, stdin, paste or file"
                    ))
                }
            }
            if let plan = string(["agents", name, "plan"]) { agent.planArguments = plan.isEmpty ? nil : plan }
            if let flag = string(["agents", name, "model_flag"]) { agent.modelFlag = flag.isEmpty ? nil : flag }
            if let resume = string(["agents", name, "resume"]) {
                agent.resumeArguments = resume.isEmpty ? nil : resume
            }
            for (profile, line) in pairs(["agents", name, "profiles"]) {
                agent.profiles[profile] = line
            }
            config.work.agents[index] = agent
        }

        // [keys]
        if let escape = string(["keys", "insert_escape"]) { config.insertEscape = escape }
        if let shortcut = string(["keys", "global_activate"]) { config.globalActivate = shortcut }
        // [ui]
        if let flag = bool(["ui", "menu_bar"]) { config.showMenuBarItem = flag }
        if let flag = bool(["ui", "dock_state"]) { config.showDockState = flag }

        if let keys = root.value(at: ["keys"])?.table {
            // Tables are modes or views; plain values are the settings above, and unknown ones are ignored.
            for name in keys.keys where keys[name]?.table != nil {
                let entries = pairs(["keys", name])
                if let mode = Mode(rawValue: name) {
                    config.keys[mode] = entries
                } else if DefaultKeys.scoped[name] != nil || ["issues", "prs"].contains(name) {
                    config.scopedKeys[name] = entries
                } else if !["repos", "sessions", "history"].contains(name) {
                    problems.append(ConfigProblem(path: "keys.\(name)", message: "not a mode or a view"))
                }
            }
        }
        return (config, problems)
    }

    /// The commented config written on first launch. Every key is shown with its default.
    public static let defaultSource = """
    # Heed configuration. Saved changes apply right away; mistakes are reported in the status bar and the last good
    # config stays in use. Settings (⌘,) edits this file too, except key bindings, which live only here.

    [sessions]
    # On launch: ask which tasks' agents to resume (each agent tab resumes its own Claude session), all, or none.
    resume_on_launch = "ask"           # ask | always | never
    # Typed into a resumed agent that was mid-turn, once it is idle. "" turns it off.
    continue_prompt = "Continue where you left off."
    # Open a shell split beside the agent in new tasks.
    shell_split = false
    # Keep every pane's terminal alive in a zmx session, so agents keep running when heed quits, restarts or updates,
    # and come back as they were: auto (zmx when it is installed and works; Settings > General shows its check),
    # zmx, or none (panes end with heed).
    persist = "auto"

    [github]
    # How often the view on screen refreshes from GitHub; the others refresh five times less often.
    poll_seconds = 60

    [ui]
    # A menu bar item: an owl that shows how many tasks need you, with those tasks and Open Heed.
    menu_bar = true
    # The Dock icon shows the same: a badge in the state's colour (blocked, else asking) with the count.
    dock_state = true

    [tools]
    # Where git and gh are. Empty means detect: your login shell's PATH (fish, zsh, bash, nu), then the usual places
    # (Homebrew, mise, nix, ~/.local/bin), then /usr/bin. Set a path when detection picks the wrong one.
    git = ""                           # e.g. "/opt/homebrew/bin/git"
    gh = ""
    # Directories searched first, for git, gh and agent commands alike.
    path = []

    [pk]
    # The python of pk's virtualenv. Tasks are pk's notes: Heed reads and changes them through `python -m pk.bridge`.
    python = "~/www/pk/.venv/bin/python"

    # The agent: claude, overridden field by field. Fields: command, prompt (argument | stdin | paste | file), plan,
    # resume ("{id}" is the agent's session id), and [agents.claude.profiles] of name = command line. Other agents run
    # in a plain terminal tab, without status.
    [agents.claude]
    command = "claude"
    plan = "--permission-mode plan"
    resume = "--resume {id}"

    # Pinned commands: each opens as a tab in a task's worktree when the task gets one; the exit code sets the tab's
    # glyph.
    [commands]
    # jest = "yarn test:jest"

    [keys]
    # Leaves INSERT. It is also the terminal's quit signal, so pick something else if you need that.
    insert_escape = "<C-\\\\>"
    # Brings Heed to the front from any app; "" turns it off.
    global_activate = "<C-M-h>"
    # Shift+Escape leaves INSERT too; a plain Escape always goes to the terminal. [keys.insert] "<S-Esc>" = "" unbinds.

    # Bindings per mode ([keys.normal], [keys.visual], ...) or per view ([keys.tasks], [keys.inbox], [keys.issues],
    # [keys.diff], [keys.pr]), in vim notation, each naming a command (the same names : completes). "" unbinds.
    # [keys.browser] is for a focused web page: single ⌘ or ⌃ chords, which work while you type in the page too.
    # [keys.normal]
    # "gB" = ""
    # "<C-j>" = "row.next"
    """
}
