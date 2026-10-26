import HeedCore
import SwiftUI

/// Settings (⌘,): a view of config.toml that writes single values back into it, comments and layout kept. Key
/// bindings are shown but edited only in the file. design/screens/Agents.png, Colors.png.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var section: Section

    /// Opens on `section` (General; screenshots open others).
    init(section: Section = .general) {
        _section = State(initialValue: section)
    }

    enum Section: String, CaseIterable, Identifiable {
        /// `:settings.open <name>`: the first word of the section's title, or a short name.
        static func named(_ name: String) -> Section? {
            let key = name.lowercased()
            let short: [String: Section] = [
                "general": .general, "agents": .agents, "colors": .colors, "repos": .colors, "orgs": .colors,
                "worktrees": .worktrees, "keys": .keys, "modes": .keys,
            ]
            return short[key]
        }

        case general = "General", agents = "Agents", colors = "Repos", worktrees = "Worktrees"
        case keys = "Keys & modes"

        var id: String { rawValue }
    }

    var body: some View {
        content
            // `:settings.open agents` turns the window to that section, open or not.
            .onChange(of: model.settingsSection, initial: true) { _, asked in
                if let asked {
                    section = asked
                    model.settingsSection = nil
                }
            }
    }

    private var content: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Section.allCases) { item in
                    Text(item.rawValue)
                        .font(Theme.ui(13))
                        .foregroundStyle(section == item ? Theme.fg : Theme.fg2)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(section == item ? Theme.bg3 : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { section = item }
                }
                Spacer()
                Button("Open config.toml") { NSWorkspace.shared.open(model.configFile) }
                    .buttonStyle(.link)
                    .padding(14)
                Text(Paths.abbreviate(model.configFile.path)).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                    .padding(.horizontal, 14).padding(.bottom, 14)
            }
            .padding(.top, 14)
            .frame(width: 190)
            .background(Theme.bg2)
            Theme.line.frame(width: 1)
            ListScroll {
                VStack(alignment: .leading, spacing: 18) {
                    if let problem = model.configProblems.first {
                        Text("config.toml: \(problem.description)")
                            .font(Theme.ui(12))
                            .foregroundStyle(Theme.err)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.err.opacity(0.1)))
                    }
                    switch section {
                    case .general: GeneralSettings()
                    case .agents: AgentSettings()
                    case .colors: OrgRepoSettings()
                    case .worktrees: WorktreeSettings()
                    case .keys: KeySettings()
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .background(Theme.bg)
        .foregroundStyle(Theme.fg)
    }
}

/// A group of settings on a page: its name over a rule.
private struct GroupLabel: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: title)
            Theme.line.frame(height: 1)
        }
        .padding(.top, 10)
    }
}

/// A labelled row.
private struct Field<Content: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label).font(Theme.ui(13)).foregroundStyle(Theme.fg2).frame(width: 170, alignment: .leading).padding(
                .top,
                4
            )
            VStack(alignment: .leading, spacing: 4) {
                content
                if let detail {
                    Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).fixedSize(
                        horizontal: false,
                        vertical: true
                    )
                }
            }
        }
    }
}

/// A text field that writes to config.toml when you press return or leave it.
private struct ConfigTextField: View {
    @Environment(AppModel.self) private var model
    let path: [String]
    let value: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(Theme.mono(12.5))
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { if !focused { text = value } }
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
    }

    private func save() {
        guard text != value else { return }
        model.setConfig(path, .string(text))
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let work = model.config.work
        VStack(alignment: .leading, spacing: 16) {
            Text("General").font(Theme.ui(17, weight: .semibold))
            GroupLabel(title: "Sessions")
            Field(
                label: "Resume on launch",
                detail: "Ask lists the sessions that were open; Always resumes them; Never starts empty."
            ) {
                Picker("", selection: Binding(
                    get: { work.resumeOnLaunch },
                    set: { model.setConfig(["sessions", "resume_on_launch"], .string($0.rawValue)) }
                )) {
                    ForEach(ResumePolicy.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            Field(
                label: "Continue prompt",
                detail: "Typed into a resumed session that was mid-turn, once idle. Empty turns it off."
            ) {
                ConfigTextField(path: ["sessions", "continue_prompt"], value: work.continuePrompt)
            }
            Field(label: "Shell split", detail: "New sessions open a shell beside the agent; off is one pane.") {
                Toggle("", isOn: Binding(
                    get: { work.shellSplit }, set: { model.setConfig(["sessions", "shell_split"], .bool($0)) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            Field(
                label: "Persistent panes",
                detail: "Panes run in zmx, so agents keep running when heed quits, restarts or updates, and come back as "
                    + "they were. Auto uses zmx when it is installed and passes its check (Tools, below)."
            ) {
                Picker("", selection: Binding(
                    get: { model.settings.persist },
                    set: { model.setConfig(["sessions", "persist"], .string($0.rawValue)) }
                )) {
                    Text("Auto").tag(PanePersistence.auto)
                    Text("zmx").tag(PanePersistence.zmx)
                    Text("Off").tag(PanePersistence.none)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            GroupLabel(title: "Outside the window")
            Field(
                label: "Menu bar item",
                detail: "How many sessions need you, those sessions and Open Heed. With it on, closing the window keeps Heed running."
            ) {
                Toggle("", isOn: Binding(
                    get: { model.config.showMenuBarItem }, set: { model.setConfig(["ui", "menu_bar"], .bool($0)) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            Field(
                label: "Dock state",
                detail: "A badge on the Dock icon in the state's colour when sessions need you."
            ) {
                Toggle("", isOn: Binding(
                    get: { model.config.showDockState }, set: { model.setConfig(["ui", "dock_state"], .bool($0)) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            GroupLabel(title: "GitHub")
            Field(label: "GitHub poll", detail: "Seconds between gh syncs.") {
                Stepper(value: Binding(
                    get: { model.config.githubPollSeconds },
                    set: { model.setConfig(["github", "poll_seconds"], .integer($0)) }
                ), in: 15 ... 3600, step: 15) {
                    Text("\(model.config.githubPollSeconds)s").font(Theme.mono(12.5))
                }
                .frame(width: 160)
            }
            Field(
                label: "Issues",
                detail: "For repos without their own setting: every open issue, or only yours (assigned or mentioning you)."
            ) {
                Picker("", selection: Binding(
                    get: { model.config.issues.fallback },
                    set: { model.setConfig(["issues", "default"], .string($0.rawValue)) }
                )) {
                    Text("All issues").tag(IssueVisibility.all)
                    Text("Only yours").tag(IssueVisibility.involved)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            GroupLabel(title: "Tools")
            Field(label: "git", detail: "Empty detects it. A path, or a name looked up on the search path.") {
                ConfigTextField(path: ["tools", "git"], value: model.config.tools.git)
            }
            Field(label: "gh", detail: "Empty detects it.") {
                ConfigTextField(path: ["tools", "gh"], value: model.config.tools.gh)
            }
            Field(
                label: "zmx",
                detail: "For persistent panes. Empty detects it (Homebrew, ~/.local/bin, the search path)."
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    ConfigTextField(path: ["tools", "zmx"], value: model.config.tools.zmx)
                    ZmxStatus(health: model.zmxHealth, setting: model.settings.persist)
                }
            }
            ToolsList(report: model.tools)
        }
    }
}

private struct AgentSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let agents = model.config.work.agents
        VStack(alignment: .leading, spacing: 16) {
            Text("Agents").font(Theme.ui(17, weight: .semibold))
            if let agent = agents.first {
                GroupLabel(title: agent.name)
                Field(label: "Command") {
                    ConfigTextField(path: ["agents", agent.name, "command"], value: agent.command)
                }
                Field(label: "Prompt delivery", detail: "How Start work hands the prompt over.") {
                    Picker("", selection: Binding(
                        get: { agent.prompt },
                        set: { model.setConfig(["agents", agent.name, "prompt"], .string($0.rawValue)) }
                    )) {
                        ForEach(PromptDelivery.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 300)
                }
                Field(label: "Plan first", detail: "Arguments added when Start work's “Plan first” is on.") {
                    ConfigTextField(path: ["agents", agent.name, "plan"], value: agent.planArguments ?? "")
                }
                Field(
                    label: "Resume",
                    detail: "{id} is the agent's own session id. Empty: sessions start fresh after a restart."
                ) {
                    ConfigTextField(path: ["agents", agent.name, "resume"], value: agent.resumeArguments ?? "")
                }
                Field(label: "State", detail: integration(agent.name)) {
                    Text(stateSource(agent.name)).font(Theme.mono(12)).foregroundStyle(Theme.done)
                }
            }
            Text("Other agents run in a plain terminal tab, without status.")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.fg3)
        }
    }

    private func stateSource(_ name: String) -> String {
        name == "claude" ? "full hooks (passed with --settings)" : "not reported"
    }

    private func integration(_: String) -> String {
        "Heed never edits your own agent config; hooks are passed per run where the agent allows it."
    }
}

private struct WorktreeSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Worktrees").font(Theme.ui(17, weight: .semibold))
            Field(label: "Worktree root", detail: "New worktrees go to <root>/<repo>/<name>.") {
                ConfigTextField(path: ["worktrees", "root"], value: model.config.work.worktreeRoot)
            }
            Field(label: "Repo roots", detail: "Comma separated; scanned two levels deep.") {
                RootsField(roots: model.config.work.repoRoots)
            }
        }
    }
}

private struct RootsField: View {
    @Environment(AppModel.self) private var model
    let roots: [String]
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(Theme.mono(12.5))
            .onAppear { text = roots.joined(separator: ", ") }
            .onSubmit {
                let list = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                model.setConfig(["worktrees", "repo_roots"], .array(list.map { .string($0) }))
            }
    }
}

private struct KeySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let keymap = model.engine.keymaps[.normal] ?? Keymap()
        VStack(alignment: .leading, spacing: 12) {
            Text("Keys & modes").font(Theme.ui(17, weight: .semibold))
            Text(
                "Bindings are edited in config.toml ([keys.normal], [keys.repos], ...): every binding names a command, the same names : completes."
            )
            .font(Theme.ui(12))
            .foregroundStyle(Theme.fg3)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("Leave INSERT").font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                KeyCap(text: KeyCapText.of(model.config.insertEscape))
            }
            Button("Edit bindings in config.toml") { NSWorkspace.shared.open(model.configFile) }
            ForEach(Array(keymap.bindings.enumerated()), id: \.offset) { _, binding in
                HStack(spacing: 12) {
                    Text(KeyCapText.of(binding.keys)).font(Theme.mono(12)).frame(width: 90, alignment: .leading)
                    Text(binding.command).font(Theme.mono(12)).foregroundStyle(Theme.fg2)
                    Text(Commands.spec(CommandInvocation(parsing: binding.command).name)?.summary ?? "")
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.fg3)
                }
            }
        }
    }
}

/// zmx's check, under its field: where it is, its version, whether it works, and what panes do because of it.
private struct ZmxStatus: View {
    let health: ZmxHealth?
    let setting: PanePersistence

    var body: some View {
        let effective = ZmxHealth.decide(setting, health: health)
        VStack(alignment: .leading, spacing: 4) {
            if let health {
                HStack(spacing: 6) {
                    Image(systemName: health.works ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(health.works ? Theme.done : Theme.block)
                    if let path = health.path {
                        Text(Paths.abbreviate(path)).font(Theme.mono(11.5))
                        if let version = health.version { Text(version).foregroundStyle(Theme.fg3) }
                    }
                    Text(health.works ? "works" : health.problem ?? "")
                        .foregroundStyle(health.works ? Theme.done : Theme.block)
                }
                Text(effective == .zmx
                    ? "Panes run in zmx: agents outlive heed."
                    : setting == .none ? "Off: panes end when heed quits." : "Panes are plain shells until zmx works.")
                    .foregroundStyle(Theme.fg3)
                if health.path == nil {
                    Text("Install: " + ZmxInstall.mac.joined(separator: "; ")).font(Theme.mono(11))
                        .foregroundStyle(Theme.fg2)
                        .textSelection(.enabled)
                }
            } else {
                Text("Not checked yet.").foregroundStyle(Theme.fg3)
            }
        }
        .font(Theme.ui(12))
    }
}
