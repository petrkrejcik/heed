import AppKit
import HeedCore
import Observation

/// The app's views, switched with `g` keys (`gs`, `gm`, `gi`, `gp`).
enum AppView: String, CaseIterable, Identifiable {
    case tasks, inbox, issues, prs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .inbox: "Inbox"
        case .issues: "Issues"
        case .prs: "PRs"
        }
    }

    /// The command that switches to this view; its key comes from the live keymap.
    var command: String { "view.\(rawValue)" }
}

enum Overlay: Equatable {
    case help
    case pr
    case diff

    var name: String {
        switch self {
        case .help: "help"
        case .pr: "pr"
        case .diff: "diff"
        }
    }
}

/// Everything the window draws, on the main actor.
///
/// The domain arrives as separate stored properties (tasks, layouts, agents) so Observation redraws only what reads
/// the one that changed. Every edit, from the UI or an adapter, is a `DomainChange` that goes through
/// `commit`: applied here, then to the store off the main actor, which persists it. Nothing here waits on a process,
/// the network or the disk.
@MainActor
@Observable
final class AppModel {
    static let mainWindowID = NSUserInterfaceItemIdentifier("heed.main")
    // Domain
    private(set) var tasks: [WorkTask] = [] {
        didSet {
            rebuildList()
            updateOutsideWindow()
        }
    }

    /// Tabs and panes per task id.
    private(set) var layouts: [String: TaskLayout] = [:] { didSet { rebuildList() } }
    /// What each agent tab is doing, by pane id.
    private(set) var agents: [String: AgentTab] = [:] {
        didSet {
            rebuildList()
            updateOutsideWindow()
        }
    }

    private(set) var github = GitHubState()
    private(set) var pullDetails: [String: PullDetail] = [:]
    private(set) var list = TaskList([])
    private(set) var settings: WorkSettings
    private(set) var config = HeedConfig.default
    /// What is wrong with config.toml, if anything; the last good config stays in use.
    private(set) var configProblems: [ConfigProblem] = []
    let configFile = ConfigLoader.defaultFile()
    private var configWatcher: ConfigWatcher?
    /// Results of pinned commands by pane: the exit code of the last run.
    private(set) var commandResults: [String: Int] = [:]
    /// The first-run screen, while shown.
    private(set) var firstRun: FirstRunReport?
    /// Where git and gh were found, and the search path every command and pane runs with.
    private(set) var tools: ToolReport?
    /// zmx on this Mac, as last checked (Settings › General shows it); nil until tools are detected.
    private(set) var zmxHealth: ZmxHealth?
    /// Opens the Settings window (set by the view, which has the SwiftUI action).
    var openSettings: (() -> Void)?
    /// Nil for fixtures: nothing is persisted and no adapter runs.
    private var store: DomainStore?
    let isFixture: Bool
    private var hookServer: HookServer?
    /// Where the per-run hook files live. Screenshots show a made-up home, never the real one.
    let integration = ShotMode.active
        ? IntegrationFiles(directory: URL(fileURLWithPath: "/Users/you/Library/Application Support/Heed"))
        : IntegrationFiles.default()
    /// The latest hook events per task, newest first: shown in the inspector, not persisted (agents own history).
    private(set) var events: [String: [AgentEvent]] = [:]

    // Filtering (`/`): typed in the status bar while `filtering`, one filter per view; each view shows its own as a
    // pill.
    private(set) var filtering = false
    private(set) var filters: [AppView: String] = [:] {
        didSet {
            if filters[.tasks] != oldValue[.tasks] { rebuildList() }
        }
    }

    func filter(for view: AppView) -> String { filters[view] ?? "" }
    var taskFilter: String { filter(for: .tasks) }

    // GitHub lists: cursor and picked ids per view
    private(set) var itemCursor: [AppView: Int] = [:]
    private(set) var picked: [AppView: Set<String>] = [:]
    private(set) var inboxFilter: InboxFilter = .unread
    private(set) var issueFilter: IssueFilter = .all
    /// The repo picked in the Issues repo column; nil is all of them.
    private(set) var issueRepo: Repo?

    // pk
    /// pk's bridge: the real pk, or in fixtures a fake one that answers from memory (no process, no disk).
    private var pk: PkBridge
    private var pkSync: PkSync?
    /// Where pk keeps things (vault, main checkout, ports file); nil until pk answered.
    private(set) var pkPaths: PkPaths?
    /// Panes draw their terminals once tool detection (zmx sessions to reattach) and pk's paths (the main checkout)
    /// are in; until then the window shows the cached tasks with empty panes.
    private(set) var terminalsReady: Bool
    /// Add worktree, step 2: agent tabs asked to update their task's note, by task id. The worktree follows on that
    /// tab's next idle after it started working, after three minutes, or on the key again.
    private var worktreeWaits: [String: WorktreeWait] = [:]
    /// When each task last asked pk for its PR (on an agent going idle), so gh is not asked every turn.
    private var prSyncedAt: [String: Date] = [:]
    private var kibanaProbe: Task<Void, Never>?

    struct WorktreeWait {
        var pane: String
        var sawWorking = false
        var timer: Task<Void, Never>
    }

    // Resume on launch
    private(set) var resume: ResumeForm?
    /// Resumed agent tabs (pane ids) that were mid-turn: they get the continue prompt once they report idle.
    private var pendingContinue: Set<String> = []

    // Cursors
    private(set) var cursor = 0
    private var previousTaskID: String?
    /// Where VISUAL started in a GitHub list: the range from here to the cursor is picked.
    private var visualAnchor: Int?

    // Keys and modes
    private(set) var engine: ModeEngine
    private(set) var keyProblems: [Keymaps.Problem]
    var mode: Mode { engine.mode }
    var pendingKeys: String { engine.pendingDisplay }

    // Chrome
    private(set) var view: AppView = .tasks {
        didSet {
            updateScope()
            if view != oldValue { viewChangedForSync() }
        }
    }

    private(set) var overlay: Overlay? { didSet { updateScope() } }
    /// The PR open in the reader, over whatever view it was opened from.
    private(set) var reader: PullRef? { didSet { updateScope() } }
    /// The issue being read (`go` or ↩ on an issue).
    private(set) var issueReader: Issue? { didSet { updateScope() } }
    /// The PR the overlay shows (the current task's).
    private(set) var overlayPull: PullRef?

    /// Scoped key bindings follow what has focus: the diff, the PR overlay or reader, else the view.
    private func updateScope() {
        engine.scope = overlay == .diff ? "diff" : issueReader != nil ? "issue"
            : (overlay == .pr || reader != nil) ? "pr" : view.rawValue
    }

    // Diff overlay
    private(set) var diffScope: DiffScope = .all
    private(set) var diffFiles: [FileDiff] = []
    private(set) var diffCommits: [CommitSummary] = []
    private(set) var diffFileIndex = 0
    private(set) var diffRow = 0
    private(set) var diffSplit = false
    private(set) var diffLoading = false
    private var diffTask: Task<Void, Never>?

    /// Pane collapse state is a UI preference, not domain: kept in UserDefaults.
    private(set) var inspectorVisible = UserDefaults.standard.object(forKey: "inspectorVisible") as? Bool ?? true {
        didSet { if !isFixture { UserDefaults.standard.set(inspectorVisible, forKey: "inspectorVisible") } }
    }

    private(set) var sidebarCollapsed = UserDefaults.standard.bool(forKey: "sidebarCollapsed") {
        didSet { if !isFixture { UserDefaults.standard.set(sidebarCollapsed, forKey: "sidebarCollapsed") } }
    }

    private(set) var commandText = ""
    private(set) var flash: String?
    private(set) var hintText = ""
    private var hintThenInsert = false
    /// The new task dialog, while open.
    private(set) var newTask: NewTaskForm?
    /// Bumped when the focused terminal should take keyboard focus (entering INSERT, moving panes).
    private(set) var terminalFocusRequest = 0

    init(domain: Domain, settings: WorkSettings = .default, isFixture: Bool) {
        self.settings = settings
        self.isFixture = isFixture
        pk = isFixture ? FakePk(tasks: domain.tasks).bridge : Self.livePk(python: HeedConfig.defaultPkPython)
        terminalsReady = isFixture
        let built = Keymaps.build()
        engine = ModeEngine(keymaps: built.keymaps, scoped: built.scoped)
        keyProblems = built.problems
        if isFixture {
            // UserDefaults reads the real Mac's preferences even with HOME pointed elsewhere.
            inspectorVisible = true
            sidebarCollapsed = false
            zmxHealth = ZmxHealth(path: "/opt/homebrew/bin/zmx", version: "0.8.1")
            issueInfo = Fixtures.issueInfo
        }
        replace(with: domain)
        updateScope()
    }

    // MARK: Domain

    /// Draws the cache first, then tasks come from pk. Panes get their terminals once tools are detected and pk said
    /// where the main checkout is.
    func start(cache file: URL) async {
        startConfig()
        startHooks()
        let integration = integration
        Task.detached(priority: .utility) {
            do { try integration.write() } catch { NSLog("heed: could not write hook files: \(error)") }
        }
        let cached = await DomainStore.load(from: file)
        replace(with: cached)
        store = DomainStore(domain: cached, file: file)
        await detectTools()
        await startPk()
        // Before any terminal is made: which panes still have a live zmx session to reattach to.
        await TerminalSurfaces.shared.refreshLivePanes()
        terminalsReady = true
        loadAvatars()
        startKibanaProbe()
        await offerResume(domain: currentDomain)
        startGitHubSync()
    }

    // MARK: pk

    /// The real pk, run with the detected PATH so it finds git and gh even when Heed was opened from Finder.
    private static func livePk(python: String) -> PkBridge {
        PkBridge.live(python: Paths.expand(python)) {
            await ["PATH": ToolLocator.shared.report().pathVariable]
        }
    }

    /// Asks pk where things are, then keeps the tasks in step with its notes (and the ports file) from there on.
    private func startPk() async {
        guard !isFixture else { return }
        await pkSync?.stop()
        let sync = PkSync(
            bridge: pk,
            tasks: { [weak self] in await MainActor.run { self?.tasks ?? [] } },
            apply: { [weak self] changes in await MainActor.run { self?.applyFromPk(changes) } },
            report: { [weak self] message in await MainActor.run { self?.flash = message } }
        )
        pkSync = sync
        if let paths = await sync.start() {
            pkPaths = paths
            Kibana.configuredMain = paths.kibanaMain
        }
    }

    /// What pk found. A task that went (its note deleted, or no longer a task) takes its terminals with it.
    private func applyFromPk(_ changes: [DomainChange]) {
        for case let .taskRemoved(id) in changes {
            worktreeWaits.removeValue(forKey: id)?.timer.cancel()
            for pane in layouts[id]?.panes ?? [] {
                PaneSurfaces.close(paneID: pane.id)
            }
        }
        commit(changes)
    }

    /// One task as pk returned it after a change Heed asked for, with a line in its timeline.
    private func upsert(_ fresh: PkTask, record: String? = nil) -> WorkTask? {
        guard var task = WorkTask(fresh, keeping: fresh.id.flatMap(task)) else {
            flash = "pk returned \(fresh.title) without a task id"
            return nil
        }
        if let record { task.record(record) }
        commit(.taskUpserted(task))
        return task
    }

    /// `r` in Tasks: every task from pk again.
    private func refreshTasks() {
        Task {
            if let pkSync {
                await pkSync.refresh()
            } else if let listed = try? await pk.list() {
                applyFromPk(TaskSync.reconcile(listed.tasks, into: tasks))
            }
            flash = "tasks read from pk"
        }
    }

    /// "Kibana running" is whether the task's port listens: probed every few seconds for the listed tasks, so it
    /// shows however Kibana was started. The ports themselves are pk's.
    private func startKibanaProbe() {
        kibanaProbe?.cancel()
        kibanaProbe = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ports = Set(list.ordered.compactMap(\.port))
                let listening = await PortProbe.listening(ports)
                let changes = TaskSync.running(listening: listening, probed: ports, in: tasks)
                if !changes.isEmpty { commit(changes) }
                kibanaProbed = true
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Set after the first probe: a Kibana found running at launch (or cached as running) was not started now.
    private var kibanaProbed = false

    /// Each started Kibana gets its page about 5 seconds later, as pk waited before opening Chrome.
    private func kibanaStarted(_ taskIDs: [String]) {
        for id in taskIDs {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.openKibanaPage(id)
            }
        }
    }

    /// In the background: a new tab at the end with the active tab kept, or a reload of the page already there.
    private func openKibanaPage(_ taskID: String) {
        guard let task = task(taskID), task.running, !task.status.endsTask else { return }
        switch KibanaPage.action(url: task.kibanaURL, layout: layouts[taskID]) {
        case let .open(url):
            var layout = layouts[taskID] ?? TaskLayout(tabs: [])
            layout.openPage(url, directory: task.directory, show: false)
            commit(.layoutChanged(task: taskID, layout))
        case let .reload(pane):
            BrowserSurfaces.shared.reload(pane)
        case nil:
            break
        }
    }

    // MARK: GitHub

    private var githubTask: Task<Void, Never>?
    private(set) var syncing = false

    private var syncSchedule = SyncSchedule()

    /// Syncs now and then every `poll_seconds`: what the window shows each time, the rest every fifth time. A failed
    /// sync keeps the cached data and marks it offline.
    private func startGitHubSync() {
        githubTask?.cancel()
        githubTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await syncGitHub(force: false)
                try? await Task.sleep(for: .seconds(syncSchedule.front))
            }
        }
    }

    /// The parts the window is showing now.
    private var frontParts: Set<GitHubPart> {
        switch view {
        case .inbox: [.inbox]
        case .issues: [.issues]
        // Tasks show their PRs' state.
        case .tasks, .prs: [.pulls]
        }
    }

    /// `force` (gr refresh, :github.sync, signing in): every part. Otherwise what is due; `parts` asks for some now.
    func syncGitHub(force: Bool = true, parts wanted: Set<GitHubPart> = []) async {
        guard !isFixture, !syncing else { return }
        syncSchedule.front = TimeInterval(config.githubPollSeconds)
        let parts = wanted.isEmpty ? syncSchedule.due(now: Date(), front: frontParts, force: force) : wanted
        guard !parts.isEmpty else {
            refreshTrackedDetails()
            return
        }
        syncing = true
        defer { syncing = false }
        let previous = github
        let tracked = Array(Set(tasks.compactMap(\.pull)))
        do {
            let state = try await GitHub.sync(parts: parts, tracked: tracked, previous: previous)
            syncSchedule.fetched(parts, at: Date())
            commit(.githubSynced(state))
            refreshTrackedDetails()
            await refreshIssueInfo()
        } catch {
            var offline = previous
            offline.status = .offline("\(error)")
            commit(.githubSynced(offline))
        }
    }

    /// Switching to a view whose data is older than a poll fetches it right away instead of on the next tick.
    private func viewChangedForSync() {
        guard !isFixture, github.syncedAt != nil else { return }
        let due = syncSchedule.due(now: Date(), front: frontParts).intersection(frontParts)
        if !due.isEmpty { Task { await syncGitHub(parts: due) } }
    }

    // MARK: Resume on launch

    /// Works out what to resume (checking which Claude sessions still exist, off the main actor) and asks, resumes or
    /// does nothing, per `resumeOnLaunch`.
    /// `asked`: `:resume`, which always shows the dialog (never resuming silently) and says when there is nothing.
    private func offerResume(domain: Domain, asked: Bool = false) async {
        guard asked || settings.resumeOnLaunch != .never, !domain.tasks.isEmpty else {
            if asked { flash = "no tasks to resume" }
            return
        }
        guard !isFixture else {
            if asked { showResumeForFixture() }
            return
        }
        let settings = settings
        let integration = integration
        let found = await Task.detached(priority: .userInitiated) {
            Resume.candidates(domain: domain, settings: settings, integration: integration) { id, directory in
                AgentIntegration.hasSession(agent: "claude", id: id, directory: directory)
            }
        }.value
        // An agent whose pane's zmx session is alive never stopped: its pane reattaches, there is nothing to resume.
        let live = TerminalSurfaces.shared.livePanes
        let candidates = found.filter { candidate in !candidate.panes.allSatisfy { live.contains($0.pane) } }
        guard !candidates.isEmpty else {
            if asked { flash = "nothing to resume: every task's agents are running or gone" }
            return
        }
        if settings.resumeOnLaunch == .always, !asked {
            resumeTasks(candidates.filter(\.defaultSelected))
        } else {
            resume = ResumeForm(candidates: candidates)
        }
    }

    /// Fixture: open on the resume dialog for the fixture's tasks, without checking any files.
    func showResumeForFixture() {
        resume = ResumeForm(candidates: Resume.candidates(
            domain: Domain(tasks: tasks, layouts: layouts, agents: agents), settings: settings,
            integration: integration
        ))
    }

    private func handleResume(_ stroke: KeyStroke) {
        guard var form = resume else { return }
        switch form.handle(stroke) {
        case .handled:
            resume = form
        case let .resume(chosen):
            resume = nil
            resumeTasks(chosen)
        case .startEmpty:
            resume = nil
        }
    }

    /// Starts each chosen task's agent tabs on their resume (or fresh) commands, now, even off screen. A tab whose
    /// zmx session is still alive is left as it is.
    private func resumeTasks(_ chosen: [ResumeCandidate]) {
        guard !isFixture else {
            flash = "fixture: no IO"
            return
        }
        let live = TerminalSurfaces.shared.livePanes
        for candidate in chosen {
            guard var layout = layouts[candidate.id], var task = task(candidate.id) else { continue }
            var changes: [DomainChange] = []
            var started: [PaneSpec] = []
            for pane in candidate.panes where !live.contains(pane.pane) {
                guard let tabIndex = layout.tabs.firstIndex(where: { $0.tree.contains(pane.pane) }) else { continue }
                layout.tabs[tabIndex].tree = layout.tabs[tabIndex].tree.updating(pane.pane) {
                    $0.command = pane.command
                }
                var agent = agents[pane.pane] ?? AgentTab()
                agent.state = ObservedState(.idle, source: .guessed, reason: "resuming")
                agent.claudeSessionID = pane.claudeSessionID
                changes.append(.agentChanged(pane: pane.pane, agent))
                if let spec = layout.tabs[tabIndex].tree.panes.first(where: { $0.id == pane.pane }) {
                    started.append(spec)
                }
                if candidate.mode == .resumeThenContinue, !pane.fresh, !settings.continuePrompt.isEmpty {
                    pendingContinue.insert(pane.pane)
                }
            }
            task.record(candidate.mode == .startFresh ? "relaunched · started fresh" : "resumed after restart")
            commit([.layoutChanged(task: task.id, layout), .taskUpserted(task)] + changes)
            for pane in started {
                TerminalSurfaces.shared.autostartPanes.insert(pane.id)
                TerminalSurfaces.shared.prepare(pane, sessionID: task.id)
            }
        }
        if !chosen.isEmpty { flash = "resumed \(chosen.count) task\(chosen.count == 1 ? "" : "s")" }
    }

    // MARK: Config

    /// Loads config.toml (writing the commented default the first time) and reloads it whenever it is saved.
    private func startConfig() {
        let watcher = ConfigWatcher(file: configFile) { [weak self] text in
            Task { @MainActor in self?.applyConfig(source: text) }
        }
        configWatcher = watcher
        applyConfig(source: watcher.start())
        if watcher.createdFile { showFirstRun() }
    }

    /// Opens the first-run screen and fills it in as gh and the agent lookups answer.
    func showFirstRun(report: FirstRunReport? = nil) {
        firstRun = report ?? FirstRunReport()
        guard report == nil, !isFixture else { return }
        // Re-checks every few seconds while the screen is open, so `gh auth login` or installing an agent in another
        // terminal shows up without a restart.
        firstRunTask?.cancel()
        firstRunTask = Task { [weak self] in
            while !Task.isCancelled, self?.firstRun != nil {
                await self?.refreshFirstRun()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private var firstRunTask: Task<Void, Never>?
    private(set) var firstRunChecking = false

    /// Gathers the report again (`r`, or on its own every few seconds). Signing in to gh starts a GitHub sync now.
    func refreshFirstRun() async {
        guard firstRun != nil, !firstRunChecking else { return }
        firstRunChecking = true
        defer { firstRunChecking = false }
        let wasSignedIn = firstRun?.githubUser != nil
        let gathered = await FirstRunReport.gather(agents: settings.agents)
        guard firstRun != nil else { return }
        firstRun = gathered
        if !wasSignedIn, gathered.githubUser != nil { await syncGitHub() }
    }

    /// Every org Heed shows: Kibana's and the GitHub items'.
    private func loadAvatars() {
        guard !isFixture else { return }
        let orgs = [Kibana.repo.org] + github.pulls.map(\.ref.repo.org) + github.inbox.map(\.repo.org)
            + github.issues.map(\.repo.org)
        Avatars.shared.load(Array(Set(orgs)))
    }

    func applyConfig(source: String) {
        let (decoded, problems) = ConfigLoader.decode(source)
        configProblems = problems
        guard let decoded else { return }
        let toolsChanged = decoded.tools != config.tools
        if decoded.pkPython != config.pkPython, !isFixture {
            pk = Self.livePk(python: decoded.pkPython)
            if pkSync != nil { Task { await startPk() } }
        }
        config = decoded
        settings = decoded.work
        if !isFixture {
            TerminalSurfaces.shared.persist = ZmxHealth.decide(decoded.work.persist, health: zmxHealth)
        }
        let built = decoded.keymaps()
        engine.setKeymaps(built.keymaps, scoped: built.scoped)
        updateScope()
        keyProblems = built.problems
        if !isFixture {
            let shortcuts: [(GlobalHotKey.Name, String, () -> Void)] = [
                (.activate, decoded.globalActivate, { [weak self] in self?.activateHeed() }),
            ]
            for (name, notation, action) in shortcuts {
                if let problem = GlobalHotKey.register(name, notation, action: action) {
                    configProblems.append(ConfigProblem(path: "", message: problem))
                }
            }
        }
        updateOutsideWindow()
        if toolsChanged, !isFixture { Task { await detectTools() } }
    }

    /// `[tools] zmx` (a path, or a name on the search path), else zmx on the search path.
    static func locateZmx(_ configured: String, searchPath: [String]) -> String? {
        let name = configured.isEmpty ? "zmx" : (configured as NSString).expandingTildeInPath
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        return searchPath.lazy.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Finds git and gh (config, login shell PATH, usual places) and hands the search path to new panes.
    func detectTools(force: Bool = false) async {
        let report = await ToolLocator.shared.configure(config.tools, force: force)
        tools = report
        TerminalSurfaces.shared.searchPath = report.pathVariable
        // zmx is yours to install: `[tools] zmx`, or found on the search path like any tool, never shipped with heed.
        TerminalSurfaces.shared.zmxPath = Self.locateZmx(config.tools.zmx, searchPath: report.searchPath)
        // Checked the way panes use it; `persist = "auto"` uses it only when it works.
        let health = await ZmxCheck.run(zmx: TerminalSurfaces.shared.zmxPath)
        zmxHealth = health
        TerminalSurfaces.shared.persist = ZmxHealth.decide(settings.persist, health: health)
        if settings.persist == .zmx, TerminalSurfaces.shared.zmxPath == nil {
            flash = "persist = \"zmx\" but zmx is not installed: \(ZmxInstall.mac.joined(separator: "; ")) (panes stay plain shells until then)"
        }
        if force {
            flash = report.problems.first
                ?? report.tools.map { "\($0.name): \(Paths.abbreviate($0.path ?? "?"))" }.joined(separator: "  ")
        }
    }

    /// Removes a key from config.toml: a setting going back to its default.
    func unsetConfig(_ path: [String]) {
        do {
            try ConfigWatcher.remove(path, in: configFile)
        } catch {
            flash = "could not write config.toml: \(error)"
        }
    }

    /// Settings writes one value into config.toml; the watcher picks the change up like any other edit.
    func setConfig(_ path: [String], _ value: TOMLValue) {
        do {
            try ConfigWatcher.set(path, to: value, in: configFile)
        } catch {
            flash = "could not write config.toml: \(error)"
        }
    }

    // MARK: Hooks

    private func startHooks() {
        let server = HookServer()
        do {
            try server.start()
        } catch {
            flash = "hooks: \(error)"
            return
        }
        hookServer = server
        Task {
            for await message in server.messages {
                receive(message)
            }
        }
    }

    /// One message from an agent's hook, applied to its task and to the agent tab it came from (`HEED_PANE_ID`; a
    /// message without a known pane goes to the task's first agent tab).
    func receive(_ message: HookMessage) {
        guard var task = task(message.session), let layout = layouts[task.id] else { return }
        let pane = message.pane.flatMap { id in layout.panes.contains { $0.id == id } ? id : nil }
            ?? layout.agentPane?.pane
        var changes: [DomainChange] = []
        switch message.kind {
        case let .state(state, reason):
            guard let pane else { return }
            var agent = agents[pane] ?? AgentTab()
            agent.state = ObservedState(state, source: .reported, reason: reason)
            agent.activity = reason.map { "\(state.rawValue) · \($0)" } ?? state.rawValue
            if state == .idle || state == .done { agent.lastTurnAt = message.sentAt }
            task.lastActivity = message.sentAt
            events[task.id] = AgentEvent.log(
                events[task.id] ?? [], adding: AgentEvent(at: message.sentAt, state: state, reason: reason)
            )
            if state == .idle, pendingContinue.remove(pane) != nil {
                TerminalSurfaces.shared.typeLine(settings.continuePrompt, paneID: pane)
                task.record("sent “\(settings.continuePrompt)”")
            }
            changes.append(.agentChanged(pane: pane, agent))
            if worktreeWaits[task.id]?.pane == pane {
                if state == .working {
                    worktreeWaits[task.id]?.sawWorking = true
                } else if state == .idle || state == .done, worktreeWaits[task.id]?.sawWorking == true {
                    commit([.taskUpserted(task)] + changes)
                    return createWorktree(for: task.id)
                }
            }
            if state == .idle || state == .done { syncPull(of: task) }
        case let .prAdd(url):
            // Sent by the agent's hooks when it opened a PR (or by `heed pr add`). A task has one PR; pk writes it.
            guard task.pr == nil, let pull = PullRef(url: url) else { return }
            link(task, url, record: "opened PR #\(pull.number)") { [weak self] in self?.fetchDetail(pull) }
            return
        case let .issueAdd(url):
            guard task.issue == nil, let issue = IssueRef(url: url) else { return }
            link(task, url, record: "linked \(issue.repo.name)#\(issue.number)") { [weak self] in
                Task { await self?.refreshIssueInfo(force: [issue]) }
            }
            return
        case let .agentSession(id, _):
            guard let pane else { return }
            var agent = agents[pane] ?? AgentTab()
            agent.claudeSessionID = id
            commit(.agentChanged(pane: pane, agent))
            return
        case let .notify(text):
            flash = "\(task.title): \(text)"
            return
        case let .commandExit(code):
            if let pane = message.pane { commandResults[pane] = code }
            return
        }
        commit([.taskUpserted(task)] + changes)
    }

    /// Writes an issue or PR link into the task's note through pk, then shows what pk wrote.
    private func link(_ task: WorkTask, _ url: String, record: String, then: @escaping @MainActor () -> Void) {
        Task {
            do {
                _ = try await upsert(pk.link(task.id, url), record: record)
                then()
            } catch {
                flash = "could not link \(url) to \(task.title): \(error)"
            }
        }
    }

    /// An agent went idle in a task with a branch and no PR yet: pk looks for a PR opened from the branch. At most
    /// every two minutes per task.
    private func syncPull(of task: WorkTask) {
        guard !isFixture, task.pr == nil, let branch = task.branch, branch != "main" else { return }
        let now = Date()
        guard now.timeIntervalSince(prSyncedAt[task.id] ?? .distantPast) > 120 else { return }
        prSyncedAt[task.id] = now
        Task {
            guard let linked = try? await pk.syncPRs(task.id) else { return }
            for fresh in linked {
                guard let pull = fresh.pr.flatMap(PullRef.init(url:)) else { continue }
                _ = upsert(fresh, record: "PR #\(pull.number) found for \(branch)")
                fetchDetail(pull)
            }
        }
    }

    func flush() async { await store?.flush() }

    private func rebuildList() {
        // The selection is a task, not a row. A task moving between groups (idle to working, say) reorders the list;
        // the cursor follows the task it was on, so what you look at and type into never changes under you. Read
        // before the rebuild: `currentTask` still indexes the old list here.
        let selected = currentTask?.id
        let filter = taskFilter
        list = TaskList(filter.isEmpty ? tasks : tasks.filter { task in
            FilterQuery.matches(
                filter,
                [task.title, task.worktreeName ?? "", task.branch ?? "", task.epic ?? ""]
                    + [task.pull.map { "#\($0.number)" } ?? ""]
            )
        }, layouts: layouts, agents: agents)
        if let selected, let index = list.ordered.firstIndex(where: { $0.id == selected }) {
            cursor = index
        } else {
            cursor = min(cursor, max(list.ordered.count - 1, 0))
        }
    }

    private func replace(with domain: Domain) {
        tasks = domain.tasks
        layouts = domain.layouts
        agents = domain.agents
        github = domain.github
        pullDetails = domain.pullDetails
        cursor = min(cursor, max(list.ordered.count - 1, 0))
    }

    /// The one way the domain changes. Only properties that actually changed are written, so only their readers redraw.
    func commit(_ changes: [DomainChange]) {
        guard !changes.isEmpty else { return }
        let before = currentDomain
        let after = before.applying(changes)
        if after.github != before.github { github = after.github }
        if after.github.pulls != before.github.pulls { loadAvatars() }
        if after.pullDetails != before.pullDetails { pullDetails = after.pullDetails }
        if after.tasks != before.tasks { tasks = after.tasks }
        if after.layouts != before.layouts { layouts = after.layouts }
        if after.agents != before.agents { agents = after.agents }
        if let store { Task { await store.apply(changes) } }
        if kibanaProbed { kibanaStarted(KibanaPage.started(by: changes, in: before.tasks)) }
    }

    func commit(_ change: DomainChange) { commit([change]) }

    var currentDomain: Domain {
        Domain(tasks: tasks, layouts: layouts, agents: agents, github: github, pullDetails: pullDetails)
    }

    func task(_ id: String) -> WorkTask? { tasks.first { $0.id == id } }

    /// The listed task whose PR this is.
    func task(for pull: PullRef) -> WorkTask? { list.ordered.first { $0.pull == pull } }

    /// A task's most urgent agent state, for glyphs outside the sidebar.
    func agentState(of task: WorkTask) -> ObservedState? { list.rollup(of: task.id).agent }

    /// `gB` / `gR` with more than one place to go.
    private(set) var linkPicker: LinkPicker?
    /// Titles and states of the issues tasks link to (fetched, not cached on disk).
    private(set) var issueInfo: [IssueRef: IssueInfo] = [:]
    private var issueInfoFetchedAt: [IssueRef: Date] = [:]

    // MARK: Derived

    var currentTask: WorkTask? {
        let ordered = list.ordered
        return ordered.indices.contains(cursor) ? ordered[cursor] : nil
    }

    var currentLayout: TaskLayout? { currentTask.flatMap { layouts[$0.id] } }
    var currentTabs: [PaneTab] { currentLayout?.tabs ?? [] }
    var currentTabIndex: Int { currentLayout?.activeTab ?? 0 }

    var currentTab: PaneTab? {
        let all = currentTabs
        return all.indices.contains(currentTabIndex) ? all[currentTabIndex] : nil
    }

    var blockedCount: Int { list.rollups.values.count { $0.agent?.state == .blocked } }
    var askingCount: Int { list.rollups.values.count { $0.agent?.state == .asking } }

    // MARK: Title

    struct TitleContext: Equatable {
        var lead: String?
        var main: String
        var detail: String?
    }

    /// The title bar's middle: what is open, else what the cursor is on in the current view.
    var titleContext: TitleContext? {
        if let issue = issueReader { return TitleContext(
            lead: issue.repo.name,
            main: "#\(issue.number)",
            detail: issue.title
        ) }
        if let ref = reader ?? (overlay == .pr ? overlayPull : nil) { return pullContext(ref) }
        let index = cursor(in: view)
        switch view {
        case .tasks:
            guard let task = currentTask else { return nil }
            return TitleContext(
                lead: task.worktreeName ?? "kibana", main: task.title, detail: task.pull.map { "#\($0.number)" }
            )
        case .inbox:
            let rows = inboxRows
            guard rows.indices.contains(index) else { return nil }
            let item = rows[index]
            return TitleContext(
                lead: item.repo.name,
                main: item.number.map { "#\($0)" } ?? item.kind.rawValue,
                detail: item.title
            )
        case .issues:
            let rows = issueRows
            guard rows.indices.contains(index) else { return nil }
            return TitleContext(lead: rows[index].repo.name, main: "#\(rows[index].number)", detail: rows[index].title)
        case .prs:
            let rows = pullRows
            return rows.indices.contains(index) ? pullContext(rows[index].ref) : nil
        }
    }

    private func pullContext(_ ref: PullRef) -> TitleContext {
        TitleContext(
            lead: ref.repo.name,
            main: "#\(ref.number)",
            detail: github.pull(ref)?.title ?? pullDetails[ref.description]?.title
        )
    }

    /// Hint labels for every task row and every pane of the current tab, in that order.
    /// What `f` labels: in Tasks the tasks and the panes; elsewhere the rows of the view's list.
    var hintTargets: [(label: String, target: HintTarget)] {
        let targets: [HintTarget] = switch view {
        case .tasks:
            list.ordered
                .map { HintTarget.task($0.id) } + (currentTab?.tree.panes.map { HintTarget.pane($0.id) } ?? [])
        case .inbox, .issues, .prs: itemIDs(view).indices.map { HintTarget.row(view, $0) }
        }
        return zip(HintLabels.generate(count: targets.count), targets).map { ($0, $1) }
    }

    func hintLabel(for target: HintTarget) -> String? {
        guard mode == .hint else { return nil }
        return hintTargets.first { $0.target == target }?.label
    }

    // MARK: Keys

    /// Returns true when the key was used by the app, false when it should go on to the terminal.
    func handle(_ stroke: KeyStroke) -> Bool {
        if confirmation != nil {
            answerConfirmation(stroke)
            return true
        }
        if linkPicker != nil {
            answerLinkPicker(stroke)
            return true
        }
        if firstRun != nil {
            if stroke == KeyStroke("CR") || stroke == KeyStroke("CR", .command) || stroke == .escape {
                firstRun = nil
                firstRunTask?.cancel()
            } else if stroke == KeyStroke("r") {
                Task { await refreshFirstRun() }
            } else if stroke == KeyStroke("e") {
                NSWorkspace.shared.open(configFile)
            }
            return true
        }
        if resume != nil {
            handleResume(stroke)
            return true
        }
        if filtering {
            typeFilter(stroke)
            return true
        }
        if newTask != nil {
            handleNewTask(stroke)
            return true
        }
        // Escape leaves a page's address field, as in a browser; a page chord (⌘W, ⌘R) leaves it and runs.
        if editingAddress != nil {
            endAddressEdit()
            if stroke == .escape { return true }
        }
        if mode == .command, stroke == KeyStroke("v", .command) {
            commandText += pastedLine()
            return true
        }
        let before = engine.mode
        engine.paneScope = focusedBrowserPane == nil ? nil : "browser"
        let outcome = engine.handle(stroke)
        switch outcome {
        case .terminal:
            // Typing into a web page is not activity on the task.
            if focusedBrowserPane == nil, var task = currentTask {
                let now = Date()
                if now.timeIntervalSince(task.lastActivity) > 60 {
                    task.lastActivity = now
                    commit(.taskUpserted(task))
                }
            }
            return false
        case let .text(stroke):
            typeText(stroke)
        case .pending, .cleared:
            break
        case let .run(invocation):
            flash = nil
            perform(invocation)
        case let .unbound(keys):
            // A ⌘ shortcut Heed does not bind is the app menu's, as in any Mac app: ⌘W closes the window, ⌘Q quits,
            // ⌘H hides, ⌘M minimises.
            if keys.count == 1, keys[0].modifiers.contains(.command) { return false }
            flash = "\(KeyNotation.format(keys)) is not bound"
        }
        if engine.mode != before { modeChanged(from: before) }
        return true
    }

    private func modeChanged(from previous: Mode) {
        if previous == .command { commandText = "" }
        if previous == .hint { hintText = "" }
        if previous == .visual { visualAnchor = nil }
        if mode == .visual { visualAnchor = [.inbox, .issues, .prs].contains(view) ? itemCursor[view] ?? 0 : nil }
        if mode == .insert { terminalFocusRequest += 1 }
    }

    private func typeText(_ stroke: KeyStroke) {
        switch mode {
        case .command:
            if stroke.key == "BS" {
                if commandText.isEmpty { engine.enter(.normal) } else { commandText.removeLast() }
            } else if stroke.key == "Space" {
                commandText += " "
            } else if !stroke.isNamed, stroke.modifiers.isEmpty {
                commandText += stroke.key
            }
        case .hint:
            guard !stroke.isNamed, stroke.modifiers.isEmpty else { return }
            hintText += stroke.key
            let matches = hintTargets.filter { $0.label.hasPrefix(hintText) }
            if let only = matches.first, matches.count == 1, only.label == hintText {
                jump(to: only.target)
            } else if matches.isEmpty {
                engine.enter(.normal)
                hintText = ""
            }
        default:
            break
        }
    }

    // MARK: Commands

    func perform(_ command: CommandInvocation) {
        let count = command.count ?? 1
        switch command.name {
        case "row.next": moveRow(by: count)
        case "row.prev": moveRow(by: -count)
        case "row.first": setRow(command.count.map { $0 - 1 } ?? 0)
        case "row.last": setRow(command.count.map { $0 - 1 } ?? Int.max)
        case "row.halfpage.down": moveRow(by: 10 * count)
        case "row.halfpage.up": moveRow(by: -10 * count)
        case "group.next": moveGroup(forward: true)
        case "group.prev": moveGroup(forward: false)
        case "task.attention":
            view = .tasks
            if let next = list.nextNeedingYou(after: cursor) { setCursor(next) } else { flash = "nobody needs you" }
        case "task.pin": togglePin()
        case "task.back": goBack()
        case "pin.jump": jumpToPin(Int(command.arguments.first ?? "") ?? 1)
        case "task.new": openNewTask(title: command.arguments.joined(separator: " "))
        case "task.status": setStatus(command.arguments.joined(separator: " "))
        case "task.worktree": addWorktree()
        case "task.review": startReview(command.arguments.first)
        case "tasks.refresh": refreshTasks()
        case "kibana.run": runKibana()
        case "resume": Task { await offerResume(domain: currentDomain, asked: true) }
        case "task.open": openTask(matching: command.arguments.joined(separator: " "))
        case "tab.go":
            if let n = command.arguments.first.flatMap(Int.init) ?? command.count, currentTabs.indices.contains(n - 1) {
                selectTab(n - 1)
            } else {
                flash = "no tab \(command.arguments.first ?? "") (this task has \(currentTabs.count))"
            }
        case "filter.clear":
            filtering = false
            clearFilter(view)
        case "issues.repo": pickIssueRepo(named: command.arguments.first)
        case "app.activate": activateHeed()
        case "pane.left": updateTab { $0.focus(.left) }
        case "pane.right": updateTab { $0.focus(.right) }
        case "pane.up": updateTab { $0.focus(.up) }
        case "pane.down": updateTab { $0.focus(.down) }
        case "pane.split.right": split(.horizontal)
        case "pane.split.below": split(.vertical)
        case "pane.zoom": updateTab { $0.zoomed.toggle() }
        case "pane.close": confirmClosePane()
        case "tab.close": closeTab()
        case "tab.next": cycleTab(by: count)
        case "tab.prev": cycleTab(by: -count)
        case "tab.new": newTab()
        case "browser.new": newPageTab(command.arguments.joined(separator: " "))
        case "browser.location":
            if let pane = focusedBrowserPane { beginAddressEdit(pane) } else { flash = "not on a web page" }
        case "browser.back", "browser.forward", "browser.reload", "browser.zoom.in", "browser.zoom.out",
             "browser.zoom.reset", "browser.external":
            pageCommand(command.name)
        case "view": if let target = AppView(rawValue: command.arguments.first ?? "") { view = target }
        case "view.tasks": view = .tasks
        case "view.inbox": view = .inbox
        case "view.issues": view = .issues
        case "view.prs": view = .prs
        case "overlay.help": overlay = overlay == .help ? nil : .help
        case "agents.stop": confirmStopAgents()
        case "overlay.diff": toggleDiff()
        case "diff.hunk.next": jumpHunk(by: 1)
        case "diff.hunk.prev": jumpHunk(by: -1)
        case "diff.file.next": moveDiffFile(by: 1)
        case "diff.file.prev": moveDiffFile(by: -1)
        case "diff.scope.next": cycleDiffScope(by: 1)
        case "diff.scope.prev": cycleDiffScope(by: -1)
        case "diff.commit": cycleDiffCommit()
        case "diff.split": diffSplit.toggle()
        case "diff.ask": askAboutHunk()
        case "diff.copy": copyDiffLocation()
        case "diff.edit": openDiffFile()
        case "overlay.close": closeTopmost()
        case "inspector.toggle": inspectorVisible.toggle()
        case "sidebar.toggle": sidebarCollapsed.toggle()
        case "mode.normal", "mode.insert", "mode.visual", "mode.command", "mode.hint":
            if command.name == "mode.insert", view != .tasks || currentTab == nil { engine.enter(.normal) }
            hintThenInsert = false
        case "hint.insert":
            engine.enter(.hint)
            hintThenInsert = true
        case "command.submit": submitCommandLine()
        case "command.complete": completeCommandLine()
        case "select.toggle": toggleRow()
        case "task.filter": startFilter()
        case "github.sync": Task { await syncGitHub() }
        case "items.start": startFromItems()
        case "items.read": markItemsRead()
        case "items.filter":
            if view == .issues {
                issueFilter = issueFilter.next
                itemCursor[.issues] = 0
            } else {
                inboxFilter = inboxFilter.next
                itemCursor[.inbox] = 0
            }
        case "issues.repo.next": cycleIssueRepo(by: 1)
        case "issues.repo.prev": cycleIssueRepo(by: -1)
        case "open.reader": openReader()
        case "open.browser": openInBrowser()
        case "open.repo": openRepo()
        case "links.pick": pickLinks()
        case "overlay.pr": togglePullOverlay()
        case "overlay.item": toggleItemOverlay()
        case "jump.back": closeReaderOrOverlay()
        case "pr.start": startFromPull()
        case "pr.task": jumpToPullTask()
        case "app.quit": NSApp.terminate(nil)
        case "config.edit": NSWorkspace.shared.open(configFile)
        case "tools.detect": Task { await detectTools(force: true) }
        case "settings.open":
            if let name = command.arguments.first {
                guard let section = SettingsView.Section.named(name) else {
                    flash = "no Settings section \(name) (\(SettingsView.Section.allCases.map(\.name).joined(separator: ", ")))"
                    return
                }
                settingsSection = section
            }
            openSettings?()
        case "welcome": showFirstRun()
        default:
            flash = "\(command.name): not built yet"
        }
    }

    /// `<Esc>` in NORMAL: the reader, then an overlay.
    private func closeTopmost() {
        if issueReader != nil {
            issueReader = nil
        } else if reader != nil {
            reader = nil
        } else if overlay != nil {
            overlay = nil
        }
        // Never a view change: views are places of their own, not layers over Tasks.
    }

    private func submitCommandLine() {
        let line = commandText.trimmingCharacters(in: .whitespaces)
        engine.enter(.normal)
        commandText = ""
        guard !line.isEmpty else { return }
        let invocation = CommandAliases.resolve(line)
        guard Commands.spec(invocation.name) != nil else {
            flash = "unknown command: \(invocation.name)"
            return
        }
        perform(invocation)
    }

    private func completeCommandLine() {
        let matches = Commands.complete(commandText)
        if matches.count == 1 { commandText = matches[0].name + (matches[0].arguments == nil ? "" : " ") }
    }

    var commandCompletions: [CommandSpec] {
        guard mode == .command, !commandText.contains(" ") else { return [] }
        return Array(Commands.complete(commandText).prefix(8))
    }

    // MARK: Rows

    private func moveRow(by delta: Int) {
        if overlay == .diff {
            let count = diffRows.count
            if count > 0 { diffRow = min(max(diffRow + delta, 0), count - 1) }
            return
        }
        if shownPull != nil, overlay == .pr || reader != nil { return }
        switch view {
        case .inbox, .issues, .prs: setRow((itemCursor[view] ?? 0) + delta)
        case .tasks: setCursor(cursor + delta)
        }
    }

    /// The current list's group of each row, and the cursor: sidebar groups, repos.
    private var rowGroups: (keys: [String], cursor: Int) {
        switch view {
        case .tasks: (list.ordered.map { list.group(of: $0.id)?.rawValue ?? "" }, cursor)
        case .inbox: (inboxRows.map(\.repo.slug), cursor(in: .inbox))
        case .issues: (issueRows.map(\.repo.slug), cursor(in: .issues))
        case .prs: (pullRows.map(\.ref.repo.slug), cursor(in: .prs))
        }
    }

    private func moveGroup(forward: Bool) {
        let (keys, from) = rowGroups
        let target = forward ? RowGroups.next(keys, from: from) : RowGroups.previous(keys, from: from)
        if let target { setRow(target) }
    }

    private func setRow(_ index: Int) {
        if [.inbox, .issues, .prs].contains(view) {
            let count = itemIDs(view).count
            guard count > 0 else { return }
            itemCursor[view] = min(max(index, 0), count - 1)
        } else {
            setCursor(index)
        }
    }

    private func setCursor(_ index: Int) {
        let count = list.ordered.count
        guard count > 0 else { return }
        let clamped = min(max(index, 0), count - 1)
        if clamped != cursor { previousTaskID = currentTask?.id }
        cursor = clamped
    }

    private func select(taskID: String) {
        if let index = list.ordered.firstIndex(where: { $0.id == taskID }) { setCursor(index) }
    }

    private func goBack() {
        guard let previous = previousTaskID else { return }
        select(taskID: previous)
    }

    private func jumpToPin(_ number: Int) {
        let pins = list.pins
        guard pins.indices.contains(number - 1) else {
            flash = "no pinned task \(number)"
            return
        }
        view = .tasks
        select(taskID: pins[number - 1].id)
    }

    /// Pins or unpins in the note, through pk; the cursor stays on the task as it moves group.
    private func togglePin() {
        guard let task = currentTask else { return }
        if !task.pinned, list.pins.count >= TaskGroup.maxPins {
            flash = "already \(TaskGroup.maxPins) pins; unpin one first"
            return
        }
        Task {
            do {
                if let pinned = try await upsert(pk.pin(task.id, !task.pinned)) { select(taskID: pinned.id) }
            } catch {
                flash = "could not \(task.pinned ? "unpin" : "pin") \(task.title): \(error)"
            }
        }
    }

    // MARK: Task status

    /// `:status done`, `dd`: the status goes into the note through pk. Done and Dropped end the task: they ask first,
    /// then close its terminals (a review's worktree goes too, when nothing would be lost).
    private func setStatus(_ text: String) {
        guard let task = currentTask else { return flash = "no task here" }
        guard let status = TaskStatus.named(text) else {
            return flash = "no status \(text.isEmpty ? "given" : text): done, blocked, in progress, review, todo, dropped"
        }
        guard status != task.status else { return flash = "\(task.title) is already \(status)" }
        guard status.endsTask else { return applyStatus(status, to: task) }
        let agents = layouts[task.id]?.panes.count { $0.role == .agent } ?? 0
        let terminals = layouts[task.id]?.panes.count ?? 0
        ask(Confirmation(
            title: "Mark \(task.title) \(status)?",
            lines: ["It leaves the sidebar; the note stays"]
                + (terminals == 0 ? [] : [
                    agents > 0 ? "Its terminals close and \(agents == 1 ? "its agent stops" : "its \(agents) agents stop")"
                        : "Its terminals close",
                ])
                + (task.isReview && task.worktreeName != nil
                    ? ["Its review worktree is removed, unless it has uncommitted or unpushed work"] : []),
            accept: status.rawValue, destructive: agents > 0
        ) { [weak self] in self?.applyStatus(status, to: task) })
    }

    private func applyStatus(_ status: TaskStatus, to task: WorkTask) {
        Task {
            let result: PkStatusResult
            do {
                result = try await pk.setStatus(task.id, status)
            } catch {
                return flash = "could not set \(task.title) to \(status): \(error)"
            }
            let onScreen = currentTask?.id == task.id
            _ = upsert(result.task, record: "status \(status)")
            if status.endsTask { closeTerminals(of: task.id, onScreen: onScreen) }
            if !result.blockers.isEmpty {
                flash = "\(task.title) is \(status); its worktree stays: \(result.blockers.joined(separator: ", "))"
            } else if let removed = result.removedWorktree {
                flash = "\(task.title) is \(status); removed \(Paths.abbreviate(removed))"
            } else {
                flash = "\(task.title) is \(status)"
            }
        }
    }

    /// A task that ended: every terminal in it closes and its tabs go. The task itself stays (it is a note).
    private func closeTerminals(of id: String, onScreen: Bool) {
        guard let layout = layouts[id], !layout.tabs.isEmpty else { return }
        if onScreen { clickedOutsideTerminal() }
        commit(.layoutChanged(task: id, TaskLayout(tabs: [])))
        for pane in layout.panes {
            PaneSurfaces.close(paneID: pane.id)
        }
    }

    // MARK: Worktrees and reviews

    /// `W`: the task gets a worktree. Its agent first writes what it knows into the note (the handover); the worktree
    /// follows when that agent is idle again, after three minutes, or on `W` again. Then a bootstrap tab, the pinned
    /// commands and a new agent in the worktree that reads the note.
    private func addWorktree() {
        guard let task = currentTask else { return flash = "no task here" }
        if worktreeWaits[task.id] != nil { return createWorktree(for: task.id) }
        guard task.worktree == nil else {
            return flash = task.worktreeName.map { "\(task.title) already has the worktree \($0)" }
                ?? "\(task.title) works in the main checkout"
        }
        guard let note = task.notePath
        else { return flash = "\(task.title) has no note yet; \(keyText(for: "tasks.refresh")) reads it" }
        guard !isFixture, let pane = focusedAgentPane(of: task.id), TerminalSurfaces.shared.hasTerminal(pane) else {
            return createWorktree(for: task.id)
        }
        TerminalSurfaces.shared.typeLine(NewTask.notePrompt(note: note), paneID: pane)
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled, self?.worktreeWaits[task.id] != nil else { return }
            self?.flash = "the agent did not finish in 3 minutes; adding the worktree anyway"
            self?.createWorktree(for: task.id)
        }
        worktreeWaits[task.id] = WorktreeWait(pane: pane, timer: timer)
        var updated = task
        updated.record("asked the agent to update the note")
        commit(.taskUpserted(updated))
        flash = "the agent is writing the note; the worktree follows when it is done (\(keyText(for: "task.worktree")) again: now)"
    }

    /// The agent tab keys go to: the focused pane of the shown tab when it is an agent, else the task's first agent.
    private func focusedAgentPane(of id: String) -> String? {
        guard let layout = layouts[id] else { return nil }
        if layout.tabs.indices.contains(layout.activeTab) {
            let tab = layout.tabs[layout.activeTab]
            if tab.tree.panes.first(where: { $0.id == tab.focused })?.role == .agent { return tab.focused }
        }
        return layout.panes.first { $0.role == .agent }?.id
    }

    /// pk makes the worktree; then the agent that wrote the note moves there with Claude's `/cd`, keeping its
    /// conversation. Without a running agent, a new one starts there and reads the note.
    private func createWorktree(for id: String) {
        let waited = worktreeWaits.removeValue(forKey: id)
        waited?.timer.cancel()
        guard let task = task(id) else { return }
        flash = "creating the worktree for \(task.title)…"
        Task {
            do {
                let fresh = try await pk.addWorktree(id)
                guard let worktree = fresh.worktree else { return flash = "pk recorded no worktree on \(task.title)" }
                let record = "worktree \((worktree as NSString).lastPathComponent)"
                if let agent = waited?.pane ?? focusedAgentPane(of: id),
                   layouts[id]?.panes.contains(where: { $0.id == agent }) == true,
                   isFixture || TerminalSurfaces.shared.hasTerminal(agent)
                {
                    moveAgent(agent, of: fresh, to: worktree, record: record)
                } else {
                    addWorkTabs(
                        to: fresh, worktree: worktree,
                        prompt: NewTask.handoverPrompt(note: fresh.notePath ?? task.notePath ?? ""), record: record
                    )
                }
            } catch {
                flash = "could not add a worktree to \(task.title): \(error)"
            }
        }
    }

    /// Types `/cd <worktree>` into the agent, records its pane as working there, and adds the setup tabs. The agent's
    /// tab is shown, and typed into when the task is still the one on screen.
    private func moveAgent(_ pane: String, of fresh: PkTask, to worktree: String, record: String) {
        guard let task = upsert(fresh, record: record) else { return }
        let added = NewTask.setupTabs(
            worktree: worktree, bootstrap: pk.commandLine(["kbn", "bootstrap"]), settings: settings
        )
        guard let layout = NewTask.movingAgent(
            pane, to: worktree, in: layouts[task.id] ?? TaskLayout(tabs: []), adding: added
        ) else { return }
        if !isFixture { TerminalSurfaces.shared.typeLine(NewTask.moveCommand(to: worktree), paneID: pane) }
        autostart(added.flatMap(\.tree.panes))
        commit(.layoutChanged(task: task.id, layout))
        flash = "\(task.title): the agent moved to \((worktree as NSString).lastPathComponent); bootstrapping"
        guard view == .tasks, currentTask?.id == task.id else { return }
        focusPane(pane)
        enterInsert()
    }

    /// `:review 299044`: pk makes the review task and imports the PR into a worktree; then the same tabs as a new
    /// worktree, with an agent told what to review.
    private func startReview(_ argument: String?) {
        guard let number = argument.flatMap(NewTask.reviewNumber) else {
            return flash = ":review <number or elastic/kibana PR URL>"
        }
        flash = "importing PR \(number) for review…"
        Task {
            do {
                let fresh = try await pk.newReview(number)
                guard let worktree = fresh.worktree, let task = upsert(fresh) else { return }
                view = .tasks
                select(taskID: task.id)
                let pr = task.pr ?? PullRef(repo: Kibana.repo, number: number).url
                addWorkTabs(
                    to: fresh, worktree: worktree,
                    prompt: "Review \(pr). The task note is at \(task.notePath ?? "?").",
                    record: "review of PR \(number) in \((worktree as NSString).lastPathComponent)"
                )
            } catch {
                flash = "could not start the review of PR \(number): \(error)"
            }
        }
    }

    /// After the task's tabs: `pk kbn bootstrap`, the pinned commands and a new agent, all in `worktree`, every one
    /// starting at once. The agent's tab is shown, and typed into when the task is still the one on screen.
    private func addWorkTabs(to fresh: PkTask, worktree: String, prompt: String, record: String) {
        guard let task = upsert(fresh, record: record) else { return }
        let built = NewTask.worktreeTabs(
            worktree: worktree, prompt: prompt, bootstrap: pk.commandLine(["kbn", "bootstrap"]), settings: settings,
            integration: integration
        )
        var layout = layouts[task.id] ?? TaskLayout(tabs: [])
        layout.tabs += built.tabs
        layout.activeTab = layout.tabs.count - 1
        autostart(built.tabs.flatMap(\.tree.panes))
        var changes: [DomainChange] = [.layoutChanged(task: task.id, layout)]
        if let agent = built.agent { changes.append(.agentChanged(pane: agent.pane, agent.tab)) }
        commit(changes)
        flash = "\(task.title): worktree \((worktree as NSString).lastPathComponent), bootstrapping"
        guard view == .tasks, currentTask?.id == task.id else { return }
        if let agent = built.agent { focusPane(agent.pane) }
        enterInsert()
    }

    /// Panes whose command should run when their terminal opens. Fixtures never start anything.
    private func autostart(_ panes: [PaneSpec]) {
        guard !isFixture else { return }
        for pane in panes where pane.command != nil {
            TerminalSurfaces.shared.autostartPanes.insert(pane.id)
        }
    }

    /// `K`: `pk kbn` in a new tab of the task, where it works. pk picks the port; the Kibana icon follows the probe.
    private func runKibana() {
        guard let task = currentTask else { return flash = "no task here" }
        if task.running, let port = task.port { return flash = "Kibana already runs on :\(port) for \(task.title)" }
        let pane = PaneSpec(role: .shell, title: "kibana", directory: task.directory, command: pk.commandLine(["kbn"]))
        autostart([pane])
        var layout = layouts[task.id] ?? TaskLayout(tabs: [])
        layout.tabs.append(PaneTab(title: "kibana", tree: .leaf(pane)))
        layout.activeTab = layout.tabs.count - 1
        commit(.layoutChanged(task: task.id, layout))
        enterInsert()
    }

    // MARK: Confirmation

    /// A destructive action waiting for y (or ↩) / n (or ⎋, q).
    struct Confirmation {
        var title: String
        /// What will happen, one line each.
        var lines: [String]
        /// What will be left alone, and why.
        var kept: [String] = []
        var accept: String
        var cancel = "Cancel"
        /// Red accept button for removals; neutral for the rest.
        var destructive = true
        var action: @MainActor () -> Void
        /// A third answer, between cancel and accept: its label, its key, and what it does.
        /// Other answers besides accept and cancel, each with its own key; `destructive` ones are drawn red.
        var alternatives: [Alternative] = []

        struct Alternative {
            var label: String
            var key: String
            var destructive = false
            var action: @MainActor () -> Void
        }

        /// What cancelling does besides closing the dialog.
        var onCancel: (@MainActor () -> Void)?
    }

    private(set) var confirmation: Confirmation?

    private func ask(_ confirmation: Confirmation) {
        if mode == .insert {
            engine.enter(.normal)
            modeChanged(from: .insert)
        }
        self.confirmation = confirmation
    }

    private func answerConfirmation(_ stroke: KeyStroke) {
        switch stroke {
        case KeyStroke("y"), KeyStroke("CR"):
            let action = confirmation?.action
            confirmation = nil
            action?()
        case KeyStroke("n"), KeyStroke("q"), .escape:
            let cancel = confirmation?.onCancel
            confirmation = nil
            flash = "cancelled"
            cancel?()
        default:
            if let alternative = confirmation?.alternatives.first(where: { stroke == KeyStroke($0.key) }) {
                confirmation = nil
                alternative.action()
            }
        }
    }

    func acceptConfirmation() { answerConfirmation(KeyStroke("y")) }
    func chooseAlternative(_ key: String) {
        answerConfirmation(KeyStroke(key))
    }

    func cancelConfirmation() { answerConfirmation(.escape) }

    /// `agents.stop`: with zmx, agents outlive heed; this ends every one of them (and every shell in a pane).
    private func confirmStopAgents() {
        guard TerminalSurfaces.shared.persist == .zmx else {
            return flash = "agents stop when heed quits ([sessions] persist = \"none\")"
        }
        let running = agents.values.count { [.working, .blocked, .asking].contains($0.state.state) }
        ask(Confirmation(
            title: "Stop every agent?",
            lines: [
                running > 0 ? "\(running) agent\(running == 1 ? " is" : "s are") working and will stop" :
                    "Agents and shells in every pane stop",
                "Tasks stay; their panes reopen as shells, and resume works as after a restart",
            ],
            accept: "Stop all"
        ) { [weak self] in
            Task { @MainActor in
                let count = await TerminalSurfaces.shared.stopAll()
                self?.flash = "stopped \(count) terminal\(count == 1 ? "" : "s")"
            }
        })
    }

    /// Set once a quit was confirmed, so the second terminate goes through.
    private(set) var quitConfirmed = false

    /// ⌘Q or Quit in the menu bar with agents running: Heed comes forward and asks. True when it asked (the quit
    /// waits for the answer), false when nothing runs and quitting can go ahead.
    func confirmQuitIfAgentsRun() -> Bool {
        // With zmx, quitting leaves the agents running: heed reattaches to them on its next launch.
        if TerminalSurfaces.shared.persist == .zmx { return false }
        let running = list.ordered.compactMap { task -> (WorkTask, AgentState)? in
            guard let state = list.rollup(of: task.id).agent?.state, [.working, .blocked, .asking].contains(state)
            else { return nil }
            return (task, state)
        }
        guard !running.isEmpty, confirmation == nil else { return confirmation != nil }
        activateHeed()
        ask(Confirmation(
            title: "Quit Heed?",
            lines: ["\(running.count) task\(running.count == 1 ? " has" : "s have") agents running that will stop"]
                + running.prefix(5).map { "\($0.0.title) · \($0.1.rawValue)" }
                + (running.count > 5 ? ["and \(running.count - 5) more"] : [])
                + ["Tasks stay and can resume on the next launch"],
            accept: "Quit"
        ) { [weak self] in
            self?.quitConfirmed = true
            NSApp.terminate(nil)
        })
        return true
    }

    /// Shell panes close at once; an agent pane asks, since its agent stops with it.
    private func confirmClosePane() {
        guard let tab = currentTab, let pane = tab.tree.panes.first(where: { $0.id == tab.focused }) else { return }
        guard pane.role == .agent else {
            closePane()
            return
        }
        ask(Confirmation(
            title: "Close the \(pane.title) pane?",
            lines: ["The agent in it stops; the task and its worktree stay"],
            accept: "Close"
        ) { [weak self] in self?.closePane() })
    }

    private func jump(to target: HintTarget) {
        let thenInsert = hintThenInsert
        hintThenInsert = false
        hintText = ""
        switch target {
        case let .task(id):
            select(taskID: id)
            engine.enter(.normal)
        case let .pane(id):
            updateTab { $0.focused = id }
            engine.enter(thenInsert ? .insert : .normal)
            if thenInsert { terminalFocusRequest += 1 }
        case let .row(view, index):
            // f moves the cursor there; F also opens it.
            engine.enter(.normal)
            itemCursor[view] = index
            if thenInsert { openReader() }
        }
    }

    // MARK: Picking rows

    private func toggleRow() {
        guard [.inbox, .issues, .prs].contains(view) else { return }
        let ids = itemIDs(view)
        let index = itemCursor[view] ?? 0
        guard ids.indices.contains(index) else { return }
        if picked[view, default: []].contains(ids[index]) {
            picked[view]?.remove(ids[index])
        } else {
            picked[view, default: []].insert(ids[index])
        }
    }

    // MARK: GitHub lists

    var inboxRows: [InboxItem] {
        let filter = filter(for: .inbox)
        return github.inbox.filter {
            inboxFilter.matches($0)
                && FilterQuery.matches(
                    filter,
                    [$0.title, $0.kind.rawValue, $0.repo.slug, $0.reason, $0.number.map { "#\($0)" } ?? ""]
                )
        }
    }

    /// Issues involving you, narrowed by the chip.
    var shownIssues: [Issue] { github.issues.filter { issueFilter.matches($0) } }

    /// The Issues repo column: repos with shown issues, most first, then by name.
    var issueRepoCounts: [(repo: Repo, count: Int)] {
        let counts = Dictionary(grouping: shownIssues, by: \.repo).mapValues(\.count)
        return counts.map { ($0.key, $0.value) }.sorted {
            $0.count != $1.count ? $0.count > $1.count
                : $0.repo.name.localizedCaseInsensitiveCompare($1.repo.name) == .orderedAscending
        }
    }

    var issueRows: [Issue] {
        let filter = filter(for: .issues)
        return shownIssues.filter {
            (issueRepo == nil || $0.repo == issueRepo)
                && FilterQuery.matches(filter, [$0.title, $0.repo.slug, "#\($0.number)", $0.author ?? ""] + $0.labels)
        }
    }

    private func cycleIssueRepo(by delta: Int) {
        let options: [Repo?] = [nil] + issueRepoCounts.map(\.repo)
        let index = options.firstIndex(of: issueRepo) ?? 0
        issueRepo = options[((index + delta) % options.count + options.count) % options.count]
        itemCursor[.issues] = 0
    }

    /// `:issues.repo docs-builder`: by name or org/name; none shows every repo.
    private func pickIssueRepo(named name: String?) {
        view = .issues
        guard let name else { return pickIssueRepo(nil) }
        let key = name.lowercased()
        guard let repo = issueRepoCounts.map(\.repo).first(where: {
            $0.slug.lowercased() == key || $0.name.lowercased() == key
        }) else {
            flash = "no issues from a repo named \(name)"
            return
        }
        pickIssueRepo(repo)
    }

    /// `:task.open upload`: the first task matching every word, as the filter matches.
    private func openTask(matching words: String) {
        guard !words.isEmpty else {
            flash = ":task.open <words> goes to the first task matching them"
            return
        }
        let matches = { (task: WorkTask) in
            FilterQuery.matches(words, [task.title, task.worktreeName ?? "", task.branch ?? ""])
        }
        if let task = list.ordered.first(where: matches) {
            view = .tasks
            return select(taskID: task.id)
        }
        guard let todo = tasks.first(where: { $0.status == .toDo && matches($0) }) else {
            return flash = "no task matches \(words)"
        }
        flash = "starting \(todo.title)…"
        Task {
            do {
                let result = try await pk.setStatus(todo.id, .inProgress)
                _ = upsert(result.task, record: "status In Progress")
                view = .tasks
                select(taskID: todo.id)
                flash = "\(todo.title) is In Progress"
            } catch {
                flash = "could not start \(todo.title): \(error)"
            }
        }
    }

    /// PRs that mention this one: shown in the reader, never linked to a task.
    func suggestedLinks(for ref: PullRef) -> [PullDetail.Reference] {
        pullDetails[ref.description]?.references ?? []
    }

    func pickIssueRepo(_ repo: Repo?) {
        issueRepo = repo
        itemCursor[.issues] = 0
    }

    var pullRows: [PullRequest] {
        let filter = filter(for: .prs)
        return github.pulls.filter {
            FilterQuery.matches(filter, [$0.title, $0.ref.repo.slug, "#\($0.ref.number)", $0.headBranch])
        }
    }

    func itemIDs(_ view: AppView) -> [String] {
        switch view {
        case .inbox: inboxRows.map(\.id)
        case .issues: issueRows.map(\.id)
        case .prs: pullRows.map(\.id)
        default: []
        }
    }

    func cursor(in view: AppView) -> Int { itemCursor[view] ?? 0 }

    /// Picked ids in a list: toggled ones plus the VISUAL range.
    func pickedIDs(_ view: AppView) -> Set<String> {
        var result = picked[view] ?? []
        if mode == .visual, self.view == view, let anchor = visualAnchor {
            let ids = itemIDs(view)
            let current = cursor(in: view)
            for index in min(anchor, current) ... max(anchor, current) where ids.indices.contains(index) {
                result.insert(ids[index])
            }
        }
        return result
    }

    /// What `s`, `a`, `m` act on: the picked items, else the one under the cursor.
    private func actionIDs(_ view: AppView) -> [String] {
        let ids = itemIDs(view)
        let chosen = pickedIDs(view)
        if !chosen.isEmpty { return ids.filter(chosen.contains) }
        let index = cursor(in: view)
        return ids.indices.contains(index) ? [ids[index]] : []
    }

    private func clearPicks() {
        picked[view] = []
        if mode == .visual {
            engine.enter(.normal)
            modeChanged(from: .visual)
        }
    }

    private var itemsPrompt: String {
        let ids = actionIDs(view)
        switch view {
        case .issues: return WorkPrompt.from(issues: github.issues.filter { ids.contains($0.id) })
        case .inbox:
            let items = inboxRows.filter { ids.contains($0.id) }
            // Issues in the inbox get their full text when Issues has it.
            let issues = items.compactMap { item in
                github.issues.first { $0.repo == item.repo && $0.number == item.number }
            }
            return issues.count == items.count ? WorkPrompt.from(issues: issues) : WorkPrompt.from(inbox: items)
        default: return ""
        }
    }

    var itemsPromptPreview: String { itemsPrompt }

    /// A title for a task started from the picked items: the item's own title when there is one.
    private var itemsTitle: String {
        let ids = actionIDs(view)
        let titles: [String] = switch view {
        case .issues: issueRows.filter { ids.contains($0.id) }.map(\.title)
        case .inbox: inboxRows.filter { ids.contains($0.id) }.map(\.title)
        default: []
        }
        return titles.count == 1 ? titles[0] : ""
    }

    private func startFromItems() {
        let prompt = itemsPrompt
        guard !prompt.isEmpty else { return }
        let title = itemsTitle
        clearPicks()
        issueReader = nil
        openNewTask(title: title, context: prompt)
    }

    private func markItemsRead() {
        guard view == .inbox else { return }
        let ids = actionIDs(.inbox)
        guard !ids.isEmpty else { return }
        commit(.inboxRead(ids))
        clearPicks()
        guard !isFixture else { return }
        Task {
            for id in ids {
                try? await GitHub.markRead(threadID: id)
            }
        }
    }

    private var urlUnderCursor: String? {
        if let issue = issueReader { return issue.url }
        if let ref = shownPull { return pullDetails[ref.description].map { _ in ref.url } ?? ref.url }
        let index = cursor(in: view)
        switch view {
        case .inbox: return inboxRows.indices.contains(index) ? inboxRows[index].url : nil
        case .issues: return issueRows.indices.contains(index) ? issueRows[index].url : nil
        case .prs: return pullRows.indices.contains(index) ? pullRows[index].url : nil
        case .tasks: return currentTask?.pull?.url
        }
    }

    /// `gB`: what is under the cursor. In Tasks (outside the overlay and reader) the task's links: one opens,
    /// several offer the picker, none opens Kibana.
    private func openInBrowser() {
        if view == .tasks, issueReader == nil, shownPull == nil, let task = currentTask {
            let links = links(of: task)
            switch links.count {
            case 0: return openRepo()
            case 1: return open(links[0], browser: true)
            default: linkPicker = LinkPicker(title: "Open in the browser", links: links)
            }
            return
        }
        guard let text = urlUnderCursor else {
            flash = "nothing to open"
            return
        }
        openLink(text, from: linkSource)
    }

    // MARK: Links

    /// The task a link opened from the screen came from: the current one in Tasks (its PR card, its overlay, its
    /// inspector); none in the other views, so their links go to Kibana main.
    var linkSource: String? { view == .tasks ? currentTask?.id : nil }

    /// A URL ⌘-clicked in a terminal: a page in that terminal's task, next to its tab.
    func openLink(_ url: String, fromPane paneID: String) {
        openLink(url, from: currentDomain.task(ofPane: paneID), nextTo: paneID)
    }

    /// Every link opened in Heed. A web link becomes a page in the task it came from, else in Kibana main, and Heed
    /// shows it, because you asked for it. Other links (`mailto:`, a file) go to the app macOS picks for them.
    func openLink(_ url: String, from source: String?, nextTo paneID: String? = nil) {
        guard LinkTarget.opensAsPage(url) else {
            let target = url.hasPrefix("/") ? URL(fileURLWithPath: url) : URL(string: url)
            if let target { NSWorkspace.shared.open(target) }
            return
        }
        guard let taskID = LinkTarget.task(from: source, in: tasks), let task = task(taskID) else {
            if let target = URL(string: url) { NSWorkspace.shared.open(target) }
            flash = "no Kibana main task to open pages in; opened in your browser"
            return
        }
        var layout = layouts[taskID] ?? TaskLayout(tabs: [])
        layout.openPage(url, nextTo: paneID, directory: task.directory, show: true)
        commit(.layoutChanged(task: taskID, layout))
        linkPicker = nil
        overlay = nil
        reader = nil
        issueReader = nil
        view = .tasks
        select(taskID: taskID)
        if mode == .insert {
            let before = engine.mode
            engine.enter(.normal)
            modeChanged(from: before)
        }
    }

    /// A task's issues: its own, then those its PR closes.
    func issues(of task: WorkTask) -> [IssueRef] {
        let closedByPull = task.pull.map { ref in
            (pullDetails[ref.description]?.closes ?? []).map { IssueRef(repo: $0.repo, number: $0.number) }
        } ?? []
        var seen: Set<IssueRef> = []
        return ([task.issueRef].compactMap(\.self) + closedByPull).filter { seen.insert($0).inserted }
    }

    /// Everything a task links to on GitHub, in the inspector's order: its PR, then its issues.
    func links(of task: WorkTask) -> [TaskLink] {
        (task.pull.map { [TaskLink.pull($0)] } ?? []) + issues(of: task).map(TaskLink.issue)
    }

    /// An issue as the reader shows it: from the issue sync when it has it, else from what was fetched for the link.
    func issue(for ref: IssueRef) -> Issue? {
        if let known = github.issues.first(where: { $0.repo == ref.repo && $0.number == ref.number }) { return known }
        guard let info = issueInfo[ref] else { return nil }
        return Issue(
            repo: ref.repo, number: ref.number, title: info.title, url: ref.url, body: info.body, labels: info.labels,
            author: info.author, updatedAt: info.updatedAt
        )
    }

    /// A link clicked or picked: a PR opens the overlay on it, an issue the reader; `browser` (⌘-click, `gB`) opens its
    /// GitHub page in Heed instead.
    func open(_ link: TaskLink, browser: Bool = false) {
        linkPicker = nil
        if browser {
            openLink(link.url, from: linkSource)
            return
        }
        switch link {
        case let .pull(ref):
            if let index = list.ordered.firstIndex(where: { $0.pull == ref }), view == .tasks {
                setCursor(index)
            }
            overlayPull = ref
            overlay = .pr
            fetchDetail(ref)
        case let .issue(ref):
            if let issue = issue(for: ref) {
                issueReader = issue
            } else {
                flash = "fetching \(ref.repo.name)#\(ref.number)…"
                Task {
                    await refreshIssueInfo(force: [ref])
                    if let issue = issue(for: ref) { issueReader = issue } else { open(link, browser: true) }
                }
            }
        case .repo:
            open(link, browser: true)
        }
    }

    /// The repo under the cursor, for `gR`: Kibana for a task, an item's.
    private var reposUnderCursor: [Repo] {
        if let issue = issueReader { return [issue.repo] }
        if let ref = shownPull, overlay == .pr || reader != nil { return [ref.repo] }
        let index = cursor(in: view)
        switch view {
        case .tasks: return currentTask == nil ? [] : [Kibana.repo]
        case .inbox: return inboxRows.indices.contains(index) ? [inboxRows[index].repo] : []
        case .issues: return issueRows.indices.contains(index) ? [issueRows[index].repo] : []
        case .prs: return pullRows.indices.contains(index) ? [pullRows[index].ref.repo] : []
        }
    }

    /// `gR`: the repo under the cursor on GitHub.
    private func openRepo() {
        guard let repo = reposUnderCursor.first else { return flash = "no repo here" }
        open(.repo(repo), browser: true)
    }

    /// `:links.pick`: the picker over the task's links (and Kibana when it has none).
    private func pickLinks() {
        guard let task = currentTask else { return flash = "no task here" }
        let links = links(of: task)
        linkPicker = LinkPicker(title: "Open in the browser", links: links.isEmpty ? [.repo(Kibana.repo)] : links)
    }

    private func answerLinkPicker(_ stroke: KeyStroke) {
        guard var picker = linkPicker else { return }
        switch picker.handle(stroke) {
        case .handled: linkPicker = picker
        case .cancel: linkPicker = nil
        case let .open(links):
            linkPicker = nil
            for link in links {
                open(link, browser: true)
            }
        }
    }

    func cancelLinkPicker() { linkPicker = nil }

    /// Fetches titles and states for the issues tasks link to: those not seen in ten minutes, and `force`.
    func refreshIssueInfo(force: [IssueRef] = []) async {
        guard !isFixture else { return }
        let now = Date()
        let wanted = Set(tasks.flatMap(issues(of:))).filter { ref in
            now.timeIntervalSince(issueInfoFetchedAt[ref] ?? .distantPast) > 600
        }.union(force)
        guard !wanted.isEmpty, let fetched = try? await GitHub.issueInfo(Array(wanted)) else { return }
        for ref in wanted {
            issueInfoFetchedAt[ref] = now
        }
        issueInfo.merge(fetched) { _, new in new }
    }

    private func jumpToPullTask() {
        let ref: PullRef
        if let open = shownPull, overlay == .pr || reader != nil {
            ref = open
        } else {
            let index = cursor(in: .prs)
            let rows = pullRows
            guard view == .prs, rows.indices.contains(index) else { return }
            ref = rows[index].ref
        }
        reader = nil
        overlay = nil
        if let task = list.ordered.first(where: { $0.pull == ref }) {
            view = .tasks
            select(taskID: task.id)
        } else {
            flash = "no task has \(ref)"
        }
    }

    // MARK: PR overlay and reader

    /// The PR the overlay or reader is about.
    var shownPull: PullRef? { reader ?? (overlay == .pr ? overlayPull : nil) }

    /// The PR under the cursor where `o` was pressed: a PRs row, a PR in the inbox, or the task's PR.
    private var pullUnderCursor: PullRef? {
        let index = cursor(in: view)
        switch view {
        case .prs: return pullRows.indices.contains(index) ? pullRows[index].ref : nil
        case .inbox:
            guard inboxRows.indices.contains(index), inboxRows[index].kind == .pr,
                  let number = inboxRows[index].number else { return nil }
            return PullRef(repo: inboxRows[index].repo, number: number)
        case .tasks: return currentTask?.pull
        case .issues: return nil
        }
    }

    private func openReader() {
        if let ref = pullUnderCursor {
            reader = ref
            fetchDetail(ref)
        } else if let issue = issueUnderCursor {
            issueReader = issue
        } else {
            openInBrowser()
        }
    }

    /// `go`: the PR or issue under the cursor, or in Tasks the task's PR overlay; again closes it.
    private func toggleItemOverlay() {
        if issueReader != nil || reader != nil {
            closeReaderOrOverlay()
        } else if view == .tasks {
            togglePullOverlay()
        } else {
            openReader()
        }
    }

    /// The issue under the cursor: an Issues row, or an issue in the inbox (with what the inbox knows of it when it
    /// is not one assigned to you).
    private var issueUnderCursor: Issue? {
        let index = cursor(in: view)
        switch view {
        case .issues:
            let rows = issueRows
            return rows.indices.contains(index) ? rows[index] : nil
        case .inbox:
            let rows = inboxRows
            guard rows.indices.contains(index), rows[index].kind == .issue, let number = rows[index].number
            else { return nil }
            let item = rows[index]
            return github.issues.first { $0.repo == item.repo && $0.number == number }
                ?? Issue(
                    repo: item.repo, number: number, title: item.title,
                    url: item.url ?? "https://github.com/\(item.repo.slug)/issues/\(number)", body: "", labels: [],
                    author: nil, updatedAt: item.updatedAt
                )
        default: return nil
        }
    }

    private func togglePullOverlay() {
        if overlay == .pr {
            overlay = nil
            return
        }
        guard let pull = currentTask?.pull else {
            flash = "this task has no PR yet"
            return
        }
        overlayPull = pull
        overlay = .pr
        fetchDetail(pull)
    }

    private func closeReaderOrOverlay() {
        if issueReader != nil {
            issueReader = nil
        } else if reader != nil {
            reader = nil
        } else if overlay != nil {
            overlay = nil
        } else {
            goBack()
        }
    }

    /// `S`: a new task on the PR, its first prompt naming the open review threads and failing checks.
    private func startFromPull() {
        guard let ref = shownPull else { return }
        let detail = pullDetails[ref.description]
        var prompt = "Continue PR \(ref.repo.name)#\(ref.number): \(detail?.title ?? "")"
        let open = (detail?.threads.filter { !$0.isResolved } ?? [])
            .map { "\($0.location) (@\($0.author)): \($0.body)" }
            + (detail?.failingChecks ?? []).map { "check \($0.name) failed: \($0.summary)" }
        if !open.isEmpty {
            prompt += "\n" + open.map { line in
                let first = line.split(separator: "\n").first.map(String.init) ?? line
                return "- " + (first.count > 160 ? String(first.prefix(159)) + "…" : first)
            }.joined(separator: "\n")
        }
        reader = nil
        overlay = nil
        openNewTask(title: detail?.title ?? "PR \(ref.number)", context: prompt)
    }

    /// Fetches a PR's detail off the main actor. Reports checks that went from failing to passing.
    func fetchDetail(_ ref: PullRef) {
        guard !isFixture else { return }
        Task {
            guard let detail = try? await GitHub.pullDetail(ref) else { return }
            let failedBefore = pullDetails[ref.description]?.failingChecks.map(\.name) ?? []
            commit(.pullDetailFetched(detail))
            let fixed = failedBefore.filter { name in
                !detail.failingChecks.contains { $0.name == name } && !detail.checks.pendingNames.contains(name)
            }
            if !fixed.isEmpty { flash = "\(fixed.joined(separator: ", ")) passing now on #\(ref.number)" }
        }
    }

    /// Details for the tasks' PRs: the one on screen every time, the others only when the last sync
    /// says their checks or threads moved, or every fifth poll.
    private func refreshTrackedDetails() {
        let open = [overlay == .pr ? overlayPull : nil, reader].compactMap(\.self)
        let now = Date()
        let refs = Set(list.ordered.compactMap(\.pull)).filter { ref in
            open.contains(ref) || syncSchedule.needsDetail(
                pull: github.pull(ref), detail: pullDetails[ref.description], now: now
            )
        }
        for ref in Set(open).union(refs).prefix(10) {
            fetchDetail(ref)
        }
    }

    // MARK: PR status

    /// Where a PR stands, from GitHub only.
    func pullStatus(for ref: PullRef) -> PullStatus {
        PullStatus.of(pull: github.pull(ref), detail: pullDetails[ref.description])
    }

    /// Where the task's PR stands, for its sidebar row.
    func pullStatus(of task: WorkTask) -> PullStatus? { task.pull.map(pullStatus(for:)) }

    // MARK: Diff overlay

    /// One row of the current file: a hunk header or a line.
    enum DiffRow: Hashable {
        case header(hunk: Int, text: String)
        case line(hunk: Int, DiffLine)
    }

    var currentDiffFile: FileDiff? { diffFiles.indices.contains(diffFileIndex) ? diffFiles[diffFileIndex] : nil }

    var diffRows: [DiffRow] {
        guard let file = currentDiffFile else { return [] }
        return file.hunks.enumerated().flatMap { index, hunk in
            [DiffRow.header(hunk: index, text: hunk.header)] + hunk.lines.map { DiffRow.line(hunk: index, $0) }
        }
    }

    private func toggleDiff() {
        if overlay == .diff {
            overlay = nil
            return
        }
        guard currentTask != nil else {
            flash = "no task"
            return
        }
        overlay = .diff
        loadDiff()
    }

    /// Diffs the current task's checkout against main, off the main actor.
    private func loadDiff() {
        guard let task = currentTask else { return }
        guard !isFixture else {
            diffFiles = Fixtures.diff
            diffCommits = Fixtures.diffCommits
            return
        }
        let directory = task.directory
        let scope = diffScope
        diffLoading = true
        diffTask?.cancel()
        diffTask = Task {
            defer { diffLoading = false }
            let files = await (try? Git.diff(at: directory, scope: scope, base: "main", repo: Kibana.repo)) ?? []
            let commits = await (try? Git.commits(at: directory, base: "main")) ?? []
            guard !Task.isCancelled else { return }
            diffFiles = files
            diffCommits = commits
            diffFileIndex = min(diffFileIndex, max(files.count - 1, 0))
            diffRow = 0
        }
    }

    private func jumpHunk(by delta: Int) {
        let rows = diffRows
        let headers = rows.indices.filter { if case .header = rows[$0] { true } else { false } }
        guard !headers.isEmpty else { return }
        if delta > 0 {
            if let next = headers.first(where: { $0 > diffRow }) { diffRow = next } else { moveDiffFile(by: 1) }
        } else if let previous = headers.last(where: { $0 < diffRow }) {
            diffRow = previous
        }
    }

    private func moveDiffFile(by delta: Int) {
        guard !diffFiles.isEmpty else { return }
        diffFileIndex = min(max(diffFileIndex + delta, 0), diffFiles.count - 1)
        diffRow = 0
    }

    private func cycleDiffScope(by delta: Int) {
        let cycle = DiffScope.cycle
        let index = cycle.firstIndex(of: diffScope) ?? 0
        diffScope = cycle[((index + delta) % cycle.count + cycle.count) % cycle.count]
        loadDiff()
    }

    private func cycleDiffCommit() {
        guard !diffCommits.isEmpty else {
            flash = "no commits on this branch yet"
            return
        }
        if case let .commit(sha) = diffScope, let index = diffCommits.firstIndex(where: { $0.sha == sha }),
           index + 1 < diffCommits.count
        {
            diffScope = .commit(diffCommits[index + 1].sha)
        } else if case .commit = diffScope {
            diffScope = .all
        } else {
            diffScope = .commit(diffCommits[0].sha)
        }
        loadDiff()
    }

    /// The file line under the cursor (the new side, else the old side).
    private var diffLocation: (path: String, line: Int)? {
        guard let file = currentDiffFile else { return nil }
        let rows = diffRows
        guard rows.indices.contains(diffRow) else { return (file.path, 1) }
        switch rows[diffRow] {
        case let .line(_, line): return (file.path, line.newNumber ?? line.oldNumber ?? 1)
        case let .header(hunk, _): return (file.path, file.hunks[hunk].newStart)
        }
    }

    private func copyDiffLocation() {
        guard let location = diffLocation else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(location.path):\(location.line)", forType: .string)
        flash = "copied \(location.path):\(location.line)"
    }

    private func openDiffFile() {
        guard let file = currentDiffFile, let root = currentTask?.directory else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: root).appendingPathComponent(file.path))
    }

    /// Types a question about the hunk into the agent's pane, unsent, and switches to INSERT there to finish it.
    private func askAboutHunk() {
        guard let location = diffLocation, let task = currentTask, let (tabIndex, paneID) = layouts[task.id]?.agentPane
        else { return }
        TerminalSurfaces.shared.typeText(
            "About \(location.path) around line \(location.line) (the hunk in my diff): ",
            paneID: paneID
        )
        overlay = nil
        updateLayout { $0.activeTab = tabIndex }
        updateTab { $0.focused = paneID }
        engine.enter(.insert)
        terminalFocusRequest += 1
    }

    // MARK: Filter

    /// `/` in any list view: typing goes to the status bar until ↩ (keep) or ⎋ (clear).
    private func startFilter() {
        guard overlay == nil, reader == nil, issueReader == nil else { return }
        filtering = true
    }

    func clearFilter(_ view: AppView) {
        filters[view] = nil
        resetCursor(view)
    }

    private func typeFilter(_ stroke: KeyStroke) {
        var text = filter(for: view)
        switch stroke {
        case .escape:
            text = ""
            filtering = false
        case KeyStroke("CR"):
            filtering = false
        case KeyStroke("BS"):
            if text.isEmpty { filtering = false } else { text.removeLast() }
        case KeyStroke("u", .control):
            text = ""
        case KeyStroke("w", .control):
            text = FilterQuery.droppingLastWord(text)
        case KeyStroke("Space"):
            text += " "
        case KeyStroke("v", .command):
            text += pastedLine()
        default:
            guard !stroke.isNamed, stroke.modifiers.isEmpty else { return }
            text += stroke.key
        }
        guard text != filter(for: view) else { return }
        filters[view] = text.isEmpty ? nil : text
        resetCursor(view)
    }

    private func resetCursor(_ view: AppView) {
        switch view {
        case .tasks: cursor = 0
        case .inbox, .issues, .prs: itemCursor[view] = 0
        }
    }

    /// How many rows the current view's filter leaves.
    var filterMatches: Int {
        switch view {
        case .tasks: list.ordered.count
        case .inbox, .issues, .prs: itemIDs(view).count
        }
    }

    // MARK: New task

    /// `o`: the new task dialog, `title` typed in already; `context` is the agent's first prompt.
    private func openNewTask(title: String = "", context: String = "") {
        newTask = NewTaskForm(title: title, context: context)
    }

    func cancelNewTask() { newTask = nil }

    /// The clipboard's text on one line, for the command line and the filter.
    private func pastedLine() -> String {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        return text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private func handleNewTask(_ stroke: KeyStroke) {
        guard var form = newTask else { return }
        if stroke == KeyStroke("v", .command), let text = NSPasteboard.general.string(forType: .string) {
            form.paste(text)
            newTask = form
            return
        }
        switch form.handle(stroke) {
        case .handled, .ignored:
            newTask = form
        case .cancel:
            newTask = nil
        case let .create(title, context):
            newTask = nil
            createTask(title: title, context: context)
        }
    }

    /// pk writes the note (In Progress, `context` under Notes); the task gets an agent in the main checkout, which
    /// takes your keys.
    private func createTask(title: String, context: String) {
        flash = "creating \(title)…"
        Task {
            let created: PkTask
            do {
                created = try await pk.new(title: title, context: context)
            } catch {
                return flash = "could not create \(title): \(error)"
            }
            guard let task = WorkTask(created, keeping: nil) else {
                return flash = "pk returned \(created.title) without a task id"
            }
            let changes = NewTask.start(task, context: context, settings: settings, integration: integration)
            for case let .layoutChanged(_, layout) in changes {
                autostart(layout.panes)
            }
            commit(changes)
            view = .tasks
            select(taskID: task.id)
            if let tab = currentTab, let agent = tab.tree.panes.first(where: { $0.role == .agent }) {
                focusPane(agent.id)
            }
            enterInsert()
            flash = "started \(task.title)"
        }
    }

    // MARK: Panes and tabs

    private func updateLayout(_ edit: (inout TaskLayout) -> Void) {
        guard let id = currentTask?.id, var layout = layouts[id] else { return }
        edit(&layout)
        commit(.layoutChanged(task: id, layout))
    }

    private func updateTab(_ edit: (inout PaneTab) -> Void) {
        updateLayout { layout in
            guard layout.tabs.indices.contains(layout.activeTab) else { return }
            edit(&layout.tabs[layout.activeTab])
        }
    }

    private func split(_ axis: PaneTree.Axis) {
        guard let task = currentTask else { return }
        let directory = currentTab?.tree.panes.first?.directory ?? task.directory
        updateTab { $0.split(axis, with: PaneSpec(role: .shell, title: "zsh", directory: directory)) }
    }

    private func closePane() {
        guard let task = currentTask, let closing = currentTab?.focused else { return }
        removePane(closing, in: task.id)
    }

    /// Takes a pane out of a task's layout (and its tab, when it was the tab's last).
    private func removePane(_ paneID: String, in taskID: String) {
        guard var layout = layouts[taskID], layout.removePane(paneID) else { return }
        commit(.layoutChanged(task: taskID, layout))
        PaneSurfaces.close(paneID: paneID)
        if layout.tabs.isEmpty { taskEmptied(taskID) }
    }

    /// A pane's terminal ended (its shell exited): the pane closes, as in any terminal.
    ///
    /// Only one at a time, though. Exits arrive in a short batch first: when terminals in more than one task end
    /// together, they were lost (heed quitting or being replaced, the terminal runtime failing), not closed, and no
    /// task is touched; they come back on the next launch. And none count while heed quits.
    func paneExited(_ paneID: String) {
        guard !terminating else { return }
        exitedPanes.insert(paneID)
        guard exitedPanes.count == 1 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            let batch = exitedPanes
            exitedPanes = []
            panesEnded(batch)
        }
    }

    /// A batch of ended terminals: closed when they are all one task's, left alone when they span tasks.
    func panesEnded(_ batch: Set<String>) {
        guard !terminating else { return }
        let domain = currentDomain
        let owners = batch.compactMap { pane in domain.task(ofPane: pane).map { (pane: pane, task: $0) } }
        guard Set(owners.map(\.task)).count <= 1 else {
            NSLog(
                "heed: \(owners.count) terminals in \(Set(owners.map(\.task)).count) tasks ended at once; tasks left as they were"
            )
            flash = "\(owners.count) terminals ended at once; tasks kept, they reopen on the next launch"
            return
        }
        for owner in owners {
            removePane(owner.pane, in: owner.task)
        }
    }

    /// Panes whose terminal ended in the last moment, gathered so a mass exit is seen as one.
    private var exitedPanes: Set<String> = []
    /// Set when heed starts quitting: terminals ending then are the quit, not someone typing exit.
    private(set) var terminating = false
    func beginTerminating() { terminating = true }

    /// `tab.close`, or a tab's ×: every pane in it. A tab with the agent in it asks first.
    func closeTab(_ index: Int? = nil) {
        guard let task = currentTask, var layout = layouts[task.id] else { return }
        let index = index ?? layout.activeTab
        guard layout.tabs.indices.contains(index) else { return }
        let panes = layout.tabs[index].tree.panes
        let close: @MainActor () -> Void = { [weak self] in
            guard let self, var layout = layouts[task.id], layout.tabs.indices.contains(index) else { return }
            layout.removeTab(at: index)
            commit(.layoutChanged(task: task.id, layout))
            for pane in panes {
                PaneSurfaces.close(paneID: pane.id)
            }
            if layout.tabs.isEmpty { taskEmptied(task.id) }
        }
        guard panes.contains(where: { $0.role == .agent }) else { return close() }
        layout.activeTab = index
        ask(Confirmation(
            title: "Close the \(layout.tabs[index].title) tab?",
            lines: ["The agent in it stops; the task and its worktree stay"],
            accept: "Close"
        ) { close() })
    }

    /// Every terminal of a task has gone. The task stays (it ends in its note, not here); `t` opens a shell in it.
    private func taskEmptied(_ id: String) {
        if mode == .insert, currentTask?.id == id { engine.enter(.normal) }
        guard let task = task(id) else { return }
        flash = "every terminal in \(task.title) has closed; \(keyText(for: "tab.new")) opens a shell"
    }

    private func cycleTab(by delta: Int) {
        updateLayout { layout in
            let count = layout.tabs.count
            guard count > 0 else { return }
            layout.activeTab = ((layout.activeTab + delta) % count + count) % count
        }
        autoInsert()
    }

    private func newTab() {
        guard let task = currentTask else { return }
        if layouts[task.id] == nil { commit(.layoutChanged(task: task.id, TaskLayout(tabs: []))) }
        let directory = currentTab?.tree.panes.first?.directory ?? task.directory
        updateLayout { layout in
            layout.tabs.append(PaneTab(title: "shell", tree: .leaf(PaneSpec(
                role: .shell, title: "zsh", directory: directory
            ))))
            layout.activeTab = layout.tabs.count - 1
        }
        autoInsert()
    }

    func selectTab(_ index: Int) {
        updateLayout { $0.activeTab = index }
        autoInsert()
    }

    // MARK: Web pages

    /// The focused pane when it is a web page on screen (Tasks, nothing over it): what ⌘L and the page's other keys
    /// act on.
    var focusedBrowserPane: String? {
        guard view == .tasks, overlay == nil, reader == nil, issueReader == nil, let tab = currentTab,
              let pane = tab.tree.panes.first(where: { $0.id == tab.focused }), pane.role == .browser
        else { return nil }
        return pane.id
    }

    /// The page whose address field you are typing in.
    private(set) var editingAddress: String?

    /// Whether keys go to the address field: only while a text field has the keyboard and its page is the one on
    /// screen. An edit left without ↩ or ⎋ (its tab or task switched away, focus moved to a terminal) ends here, so
    /// NORMAL gets its keys back instead of passing them to whatever has focus.
    func addressFieldOwnsKeys(fieldFocused: Bool) -> Bool {
        guard let editing = editingAddress else { return false }
        if fieldFocused, editing == focusedBrowserPane { return true }
        endAddressEdit()
        return false
    }

    /// A page's own chord (`[keys.browser]`) or ⌘T while you type in its address field: it still reaches Heed.
    func isPageChord(_ stroke: KeyStroke) -> Bool {
        guard editingAddress != nil else { return false }
        if case .command = engine.scopedKeymaps["browser"]?.lookup([stroke]) { return true }
        guard case let .command(line) = engine.keymaps[.normal]?.lookup([stroke]) else { return false }
        return CommandInvocation(parsing: line).name == "browser.new"
    }

    /// `browser.new` (⌘T): a tab in the current task with a page at `text`, or an empty one with its address field
    /// ready.
    private func newPageTab(_ text: String) {
        guard let task = currentTask else {
            flash = "no task to open a page in"
            return
        }
        view = .tasks
        var layout = layouts[task.id] ?? TaskLayout(tabs: [])
        let url = BrowserAddress.url(from: text)
        let pane = layout.openPage(url, directory: task.directory, show: true)
        commit(.layoutChanged(task: task.id, layout))
        if url == nil { beginAddressEdit(pane.id) }
    }

    /// A page asked for a new tab (a link with a target, ⌘-click): next to its own, in its task.
    func openPageTab(from paneID: String, url: String, show: Bool) {
        guard let taskID = currentDomain.task(ofPane: paneID), var layout = layouts[taskID] else { return }
        let directory = layout.panes.first { $0.id == paneID }?.directory ?? task(taskID)?
            .directory ?? NSHomeDirectory()
        layout.openPage(url, nextTo: paneID, directory: directory, show: show)
        commit(.layoutChanged(task: taskID, layout))
        if !show { flash = "opened in a new tab" }
    }

    /// A page went somewhere or got a title: its pane (and its tab, when alone) keeps it for the next launch.
    func pageChanged(_ paneID: String, url: String, title: String) {
        guard let taskID = currentDomain.task(ofPane: paneID), let layout = layouts[taskID] else { return }
        var edited = layout
        edited.pageChanged(paneID, url: url, title: title)
        if edited != layout { commit(.layoutChanged(task: taskID, edited)) }
    }

    /// ⌘L or a click in the address field: keys go to the field until ↩ or ⎋.
    func beginAddressEdit(_ paneID: String) {
        if mode == .insert {
            let before = engine.mode
            engine.enter(.normal)
            modeChanged(from: before)
        }
        if currentTab?.focused != paneID { focusPane(paneID) }
        editingAddress = paneID
    }

    func endAddressEdit() {
        editingAddress = nil
    }

    /// ↩ in the address field: go there (or search), and hand the keyboard to the page.
    func openAddress(_ text: String, in paneID: String) {
        endAddressEdit()
        guard let url = BrowserAddress.url(from: text) else { return }
        BrowserSurfaces.shared.load(url, paneID: paneID)
        clickedPane(paneID)
    }

    private func pageCommand(_ name: String) {
        guard let pane = focusedBrowserPane else {
            flash = "not on a web page"
            return
        }
        let pages = BrowserSurfaces.shared
        switch name {
        case "browser.back": pages.back(pane)
        case "browser.forward": pages.forward(pane)
        case "browser.reload": pages.reloadOrStop(pane)
        case "browser.zoom.in": pages.zoom(pane, by: 1.1)
        case "browser.zoom.out": pages.zoom(pane, by: 1 / 1.1)
        case "browser.zoom.reset": pages.zoom(pane, by: nil)
        case "browser.external":
            if let address = pages.address(of: pane), let url = URL(string: address) { NSWorkspace.shared.open(url) }
        default: break
        }
    }

    /// Going to a tab whose focused pane is a terminal hands it your keys, so you can type at once.
    private func autoInsert() {
        guard view == .tasks, overlay == nil, reader == nil, issueReader == nil, confirmation == nil,
              let tab = currentTab,
              let pane = tab.tree.panes.first(where: { $0.id == tab.focused }) ?? tab.tree.panes.first,
              pane.role.isTerminal
        else { return }
        enterInsert()
    }

    /// The key bound to `command` in NORMAL (first binding), as key-cap text: what the title bar shows per view.
    func keyCap(for command: String) -> String? {
        (engine.keymaps[.normal] ?? Keymap()).keys(for: command).first.map(KeyCapText.of)
    }

    func toggleSidebar() { sidebarCollapsed.toggle() }
    func toggleInspector() { inspectorVisible.toggle() }

    func focusPane(_ paneID: String) {
        updateTab { $0.focused = paneID }
    }

    /// `:settings.open agents`: the section the Settings window turns to.
    var settingsSection: SettingsView.Section?

    /// A command's key as text for hints: as bound, else `:command` (what still runs it).
    func keyText(for command: String) -> String { keyLabel(for: command) ?? ":\(command)" }

    /// The key for a command as you have it bound: NORMAL first, then the view bindings.
    func keyLabel(for command: String) -> String? {
        if let normal = keyCap(for: command) { return normal }
        for (_, keymap) in engine.scopedKeymaps.sorted(by: { $0.key < $1.key }) {
            if let keys = keymap.keys(for: command).first { return KeyCapText.of(keys) }
        }
        return nil
    }

    // MARK: Outside the window

    /// Reopens the main window after it was closed (set by the window from SwiftUI's openWindow).
    var reopenWindow: (() -> Void)?

    /// The Dock badge and the menu bar item, from the tasks that need you.
    private func updateOutsideWindow() {
        // Fixtures stay out of the Dock and menu bar, unless HEED_OUTSIDE asks (to check them against fixture states).
        guard !isFixture || ProcessInfo.processInfo.environment["HEED_OUTSIDE"] != nil else { return }
        let attention = Attention(blocked: blockedCount, asking: askingCount)
        DockState.update(attention, enabled: config.showDockState)
        MenuBarItem.shared.update(model: self, attention: attention, enabled: config.showMenuBarItem)
    }

    /// `[keys] global_activate` and Open Heed: the main window to the front, reopened if it was closed.
    func activateHeed() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier == Self.mainWindowID }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            reopenWindow?()
        }
    }

    /// A task chosen outside the window (the menu bar): Heed in front, on that task.
    func show(taskID: String) {
        view = .tasks
        select(taskID: taskID)
        activateHeed()
    }

    // MARK: Mouse

    /// Clicking into a terminal means typing there: focus that pane and enter INSERT. Without this a click left
    /// NORMAL on, and the next letters ran as commands (dd deleted a line of the list).
    func clickedPane(_ paneID: String) {
        guard newTask == nil, resume == nil, firstRun == nil, !filtering else { return }
        if currentTab?.focused != paneID { focusPane(paneID) }
        enterInsert()
    }

    /// Whether a click on a list may act: not while a dialog or form has the keyboard.
    private var clicksReachLists: Bool {
        newTask == nil && confirmation == nil && resume == nil && firstRun == nil && linkPicker == nil
    }

    /// A click on a task in the sidebar or the rail selects it; a double-click also types into its agent pane.
    func clickTask(_ id: String, insert: Bool = false) {
        guard clicksReachLists else { return }
        clickedOutsideTerminal()
        select(taskID: id)
        guard insert, let (tabIndex, paneID) = layouts[id]?.agentPane else { return }
        selectTab(tabIndex)
        clickedPane(paneID)
    }

    /// A click on a list row (Inbox, Issues, PRs) moves the cursor there; a double-click opens it, as ↩ does.
    func clickRow(_ list: AppView, _ index: Int, open: Bool = false) {
        guard clicksReachLists, view == list else { return }
        clickedOutsideTerminal()
        setRow(index)
        if open { openReader() }
    }

    /// A click outside any terminal (a list, the sidebar, the title bar) hands the keyboard back to Heed.
    func clickedOutsideTerminal() {
        guard mode == .insert else { return }
        let before = engine.mode
        engine.enter(.normal)
        modeChanged(from: before)
    }

    private func enterInsert() {
        guard mode != .insert else {
            terminalFocusRequest += 1
            return
        }
        let before = engine.mode
        engine.enter(.insert)
        modeChanged(from: before)
    }
}

/// The Issues chips (`t`).
enum IssueFilter: String, CaseIterable {
    case all = "All", assigned = "Assigned", mentioned = "Mentioned"

    var next: IssueFilter {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    func matches(_ issue: Issue) -> Bool {
        switch self {
        case .all: true
        case .assigned: issue.assigned
        case .mentioned: issue.mentioned
        }
    }
}

/// The inbox chips (`t`). CI is GitHub Actions telling you a workflow run finished (failed, mostly) on your branch.
enum InboxFilter: String, CaseIterable {
    case unread = "Unread", all = "All", prs = "PRs", issues = "Issues", review = "Review requested",
         assigned = "Assigned", ci = "CI runs"

    var next: InboxFilter {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    func matches(_ item: InboxItem) -> Bool {
        switch self {
        case .unread: item.unread
        case .all: true
        case .prs: item.kind == .pr
        case .issues: item.kind == .issue
        case .review: item.reason == "review_requested"
        case .assigned: item.reason == "assign"
        case .ci: item.kind == .ci || item.reason == "ci_activity"
        }
    }
}

enum HintTarget: Hashable {
    case task(String)
    case pane(String)
    /// A row in a view's list, by position.
    case row(AppView, Int)
}
