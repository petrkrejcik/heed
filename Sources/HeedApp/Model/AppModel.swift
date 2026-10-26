import AppKit
import HeedCore
import Observation

/// The app's views, switched with `g` keys (`gs`, `gm`, `gi`, `gp`, `gr`, `gh`).
enum AppView: String, CaseIterable, Identifiable {
    case sessions, inbox, issues, prs, repos, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: "Sessions"
        case .inbox: "Inbox"
        case .issues: "Issues"
        case .prs: "PRs"
        case .repos: "Repos"
        case .history: "History"
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
/// The domain arrives as separate stored properties (sessions, layouts, repos, worktrees) so Observation redraws only
/// what reads the one that changed. Every edit, from the UI or an adapter, is a `DomainChange` that goes through
/// `commit`: applied here, then to the store off the main actor, which persists it. Nothing here waits on a process,
/// the network or the disk.
@MainActor
@Observable
final class AppModel {
    static let mainWindowID = NSUserInterfaceItemIdentifier("heed.main")
    // Domain
    private(set) var sessions: [Session] = [] {
        didSet {
            rebuildList()
            if filters[.repos] != nil { rebuildWorktreeRows() }
            updateOutsideWindow()
        }
    }

    private(set) var layouts: [String: SessionLayout] = [:]
    private(set) var repos: [RepoRecord] = [] { didSet { if repos != oldValue { rebuildWorktreeRows() } } }
    private(set) var worktrees: [Worktree] = [] { didSet { if worktrees != oldValue { rebuildWorktreeRows() } } }
    private(set) var history: [HistoryEntry] = []
    private(set) var github = GitHubState()
    private(set) var pullDetails: [String: PullDetail] = [:]
    private(set) var list = SessionList([])
    private(set) var settings: WorkSettings
    private(set) var config = HeedConfig.default
    /// What is wrong with config.toml, if anything; the last good config stays in use.
    private(set) var configProblems: [ConfigProblem] = []
    let configFile = ConfigLoader.defaultFile()
    private var configWatcher: ConfigWatcher?
    /// Results of pinned tasks by pane: the exit code of the last run.
    private(set) var taskResults: [String: Int] = [:]
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
    /// The latest hook events per session, newest first: shown in the inspector, not persisted (agents own history).
    private(set) var events: [String: [AgentEvent]] = [:]

    // Filtering (`/`): typed in the status bar while `filtering`, one filter per view; each view shows its own as a
    // pill.
    private(set) var filtering = false
    private(set) var filters: [AppView: String] = [:] {
        didSet {
            if filters[.sessions] != oldValue[.sessions] { rebuildList() }
            if filters[.repos] != oldValue[.repos] { rebuildWorktreeRows() }
        }
    }

    func filter(for view: AppView) -> String { filters[view] ?? "" }
    var sessionFilter: String { filter(for: .sessions) }
    private(set) var historyOutcome: Outcome?
    private(set) var historyCursor = 0

    // GitHub lists: cursor and picked ids per view
    private(set) var itemCursor: [AppView: Int] = [:]
    private(set) var picked: [AppView: Set<String>] = [:]
    private(set) var inboxFilter: InboxFilter = .unread
    private(set) var issueFilter: IssueFilter = .all
    /// The repo picked in the Issues repo column; nil is all of them.
    private(set) var issueRepo: Repo?

    // Resume on launch
    private(set) var resume: ResumeForm?
    /// Resumed sessions that were mid-turn: they get the continue prompt once their agent reports idle.
    private var pendingContinue: Set<String> = []

    // Cursors
    private(set) var cursor = 0
    private var previousSessionID: String?
    private(set) var repoCursor = 0
    /// VISUAL selection in the Repos table: worktree ids toggled with space, plus the range from the anchor.
    private(set) var toggledRows: Set<String> = []
    private var visualAnchor: Int?

    // Keys and modes
    private(set) var engine: ModeEngine
    private(set) var keyProblems: [Keymaps.Problem]
    var mode: Mode { engine.mode }
    var pendingKeys: String { engine.pendingDisplay }

    // Chrome
    private(set) var view: AppView = .sessions {
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
    /// The PR the overlay shows (one of the current session's).
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
    /// The Start work dialog, while open.
    private(set) var startWork: StartWorkForm?
    /// Why the last start failed, shown in the dialog.
    private(set) var startWorkError: String?
    private(set) var startingWork = false
    /// Bumped when the focused terminal should take keyboard focus (entering INSERT, moving panes).
    private(set) var terminalFocusRequest = 0
    /// A text field owns the keyboard; the key router lets keys through to it.
    var textInputActive = false

    init(domain: Domain, settings: WorkSettings = .default, isFixture: Bool) {
        self.settings = settings
        self.isFixture = isFixture
        let built = Keymaps.build()
        engine = ModeEngine(keymaps: built.keymaps, scoped: built.scoped)
        keyProblems = built.problems
        if isFixture {
            // UserDefaults reads the real Mac's preferences even with HOME pointed elsewhere.
            inspectorVisible = true
            sidebarCollapsed = false
            config.issues = Fixtures.issueRules
            zmxHealth = ZmxHealth(path: "/opt/homebrew/bin/zmx", version: "0.8.1")
            issueInfo = Fixtures.issueInfo
        }
        replace(with: domain)
        updateScope()
    }

    // MARK: Domain

    /// Starts from the cache, then refreshes from git. The window is already up showing whatever the cache holds.
    func start(cache file: URL) async {
        startConfig()
        if !isFixture { await detectTools() }
        startHooks()
        let integration = integration
        Task.detached(priority: .utility) {
            do { try integration.write() } catch { NSLog("heed: could not write hook files: \(error)") }
        }
        let cached = await DomainStore.load(from: file)
        // Before any pane is drawn: which panes still have a live zmx session to reattach to.
        await TerminalSurfaces.shared.refreshLivePanes()
        replace(with: cached)
        loadAvatars()
        store = DomainStore(domain: cached, file: file)
        await offerResume(domain: cached)
        startGitHubSync()
        await refreshRepos()
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
        // Sessions show their PRs' state; Repos and History their PR numbers.
        case .sessions, .prs, .repos, .history: [.pulls]
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
        let tracked = Array(Set(sessions.flatMap(\.trackedPRs)))
        do {
            let state = try await GitHub.sync(
                parts: parts, tracked: tracked, previous: previous, issueRules: config.issues,
                localRepos: repos.map(\.repo)
            )
            syncSchedule.fetched(parts, at: Date())
            commit([.githubSynced(state)] + PullTracking.changes(sessions: sessions, pulls: state.pulls))
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

    /// Works out what to resume (checking which agent sessions still exist, off the main actor) and asks, resumes or
    /// does nothing, per `resumeOnLaunch`.
    /// `asked`: `:resume`, which always shows the dialog (never resuming silently) and says when there is nothing.
    private func offerResume(domain: Domain, asked: Bool = false) async {
        guard asked || settings.resumeOnLaunch != .never, !domain.sessions.isEmpty else {
            if asked { flash = "no sessions to resume" }
            return
        }
        guard !isFixture else {
            if asked { showResumeForFixture() }
            return
        }
        let settings = settings
        let integration = integration
        let found = await Task.detached(priority: .userInitiated) {
            Resume.candidates(domain: domain, settings: settings, integration: integration) { session in
                let directory = domain.layouts[session.id]?.tabs.first?.tree.panes.first?.directory ?? ""
                return AgentIntegration.hasSession(
                    agent: session.agent,
                    id: session.agentSessionID ?? "",
                    directory: directory
                )
            }
        }.value
        // An agent whose pane's zmx session is alive never stopped: its pane reattaches, there is nothing to resume.
        let live = TerminalSurfaces.shared.livePanes
        let candidates = found.filter { candidate in
            guard let layout = domain.layouts[candidate.id],
                  let (_, paneID) = agentPane(in: layout) else { return true }
            return !live.contains(paneID)
        }
        guard !candidates.isEmpty else {
            if asked { flash = "nothing to resume: every session's agent is running or gone" }
            return
        }
        if settings.resumeOnLaunch == .always, !asked {
            resumeSessions(candidates.filter(\.defaultSelected))
        } else {
            resume = ResumeForm(candidates: candidates)
        }
    }

    /// Fixture: open on the resume dialog for the fixture's sessions, without checking any files.
    func showResumeForFixture() {
        resume = ResumeForm(candidates: Resume.candidates(
            domain: Domain(sessions: sessions, layouts: layouts), settings: settings, integration: integration
        ))
    }

    private func handleResume(_ stroke: KeyStroke) {
        guard var form = resume else { return }
        switch form.handle(stroke) {
        case .handled:
            resume = form
        case let .resume(chosen):
            resume = nil
            resumeSessions(chosen)
        case .startEmpty:
            resume = nil
        }
    }

    /// Starts each chosen session's agent pane on its resume (or fresh) command, now, even off screen.
    private func resumeSessions(_ chosen: [ResumeCandidate]) {
        guard !isFixture else {
            flash = "fixture: no IO"
            return
        }
        for candidate in chosen {
            guard var layout = layouts[candidate.id], var session = sessions.first(where: { $0.id == candidate.id })
            else { continue }
            guard let (tabIndex, paneID) = agentPane(in: layout) else { continue }
            layout.tabs[tabIndex].tree = layout.tabs[tabIndex].tree.updating(paneID) { $0.command = candidate.command }
            session.record(candidate.mode == .startFresh ? "relaunched · started fresh" : "resumed after restart")
            session.state = ObservedState(.idle, source: .guessed, reason: "resuming")
            commit([.layoutChanged(session: session.id, layout), .sessionUpserted(session)])
            TerminalSurfaces.shared.autostartPanes.insert(paneID)
            if let pane = layout.tabs[tabIndex].tree.panes.first(where: { $0.id == paneID }) {
                TerminalSurfaces.shared.prepare(pane, sessionID: session.id)
            }
            if candidate.mode == .resumeThenContinue, !settings.continuePrompt.isEmpty {
                pendingContinue.insert(session.id)
            }
        }
        if !chosen.isEmpty { flash = "resumed \(chosen.count) session\(chosen.count == 1 ? "" : "s")" }
    }

    /// The pane the agent runs in: the first `.agent` pane, else the first pane.
    private func agentPane(in layout: SessionLayout) -> (Int, String)? {
        for (index, tab) in layout.tabs.enumerated() {
            if let pane = tab.tree.panes.first(where: { $0.role == .agent }) { return (index, pane.id) }
        }
        return layout.tabs.first?.tree.panes.first.map { (0, $0.id) }
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

    /// Every org Heed shows: repos, sessions, GitHub items.
    private func loadAvatars() {
        guard !isFixture else { return }
        let orgs = repos.map(\.repo.org) + sessions.flatMap(\.repos).map(\.org) + github.pulls.map(\.ref.repo.org)
            + github.inbox.map(\.repo.org) + github.issues.map(\.repo.org)
        // "local" stands for repos without a GitHub remote; github.com/local is someone else.
        Avatars.shared.load(orgs.filter { $0 != "local" })
    }

    func applyConfig(source: String) {
        let (decoded, problems) = ConfigLoader.decode(source)
        configProblems = problems
        guard let decoded else { return }
        let toolsChanged = decoded.tools != config.tools
        let issuesChanged = decoded.issues != config.issues
        config = decoded
        settings = decoded.work
        if !isFixture {
            TerminalSurfaces.shared.persist = ZmxHealth.decide(decoded.work.persist, health: zmxHealth)
        }
        let built = decoded.keymaps()
        engine.setKeymaps(built.keymaps, scoped: built.scoped)
        updateScope()
        keyProblems = built.problems
        Palette.shared.apply(decoded)
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
        // Repos that now show all issues need fetching; ones that no longer do are hidden by issueRows right away.
        if issuesChanged, !isFixture, github.syncedAt != nil { Task { await syncGitHub(parts: [.issues]) } }
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

    /// Settings writes one value into config.toml; the watcher picks the change up like any other edit.
    /// Removes a key from config.toml: an org or repo override going back to what it inherits.
    func unsetConfig(_ path: [String]) {
        do {
            try ConfigWatcher.remove(path, in: configFile)
        } catch {
            flash = "could not write config.toml: \(error)"
        }
    }

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

    /// One message from an agent's hook, applied to its session.
    func receive(_ message: HookMessage) {
        guard var session = sessions.first(where: { $0.id == message.session }) else { return }
        switch message.kind {
        case let .state(state, reason):
            session.state = ObservedState(state, source: .reported, reason: reason)
            session.activity = reason.map { "\(state.rawValue) · \($0)" } ?? state.rawValue
            session.lastActivity = message.sentAt
            events[session.id] = AgentEvent.log(
                events[session.id] ?? [], adding: AgentEvent(at: message.sentAt, state: state, reason: reason)
            )
            if state == .idle, pendingContinue.remove(session.id) != nil,
               let layout = layouts[session.id], let (_, paneID) = agentPane(in: layout)
            {
                TerminalSurfaces.shared.typeLine(settings.continuePrompt, paneID: paneID)
                session.record("sent “\(settings.continuePrompt)”")
            }
        case let .title(title):
            session.title = title
        case let .prAdd(url):
            // Sent by the agent's hooks when it opened a PR (or by `heed pr add`).
            guard let pull = PullRef(url: url), session.track(pull, because: "opened by \(session.agent)") else {
                return
            }
            fetchDetail(pull)
        case let .issueAdd(url):
            guard let issue = IssueRef(url: url), !session.issues.contains(issue) else { return }
            session.issues.append(issue)
            session.hiddenIssues.removeAll { $0 == issue }
            session.record("linked \(issue.repo.name)#\(issue.number)")
            Task { await refreshIssueInfo(force: [issue]) }
        case let .agentSession(id, _):
            session.agentSessionID = id
        case let .notify(text):
            flash = "\(session.title): \(text)"
            return
        case let .taskExit(code):
            if let pane = message.pane { taskResults[pane] = code }
            return
        }
        commit(.sessionUpserted(session))
    }

    func flush() async { await store?.flush() }

    private func rebuildList() {
        // The selection is a session, not a row. A session moving between groups (parked to working, say) reorders
        // the list; the cursor follows the session it was on, so what you look at and type into never changes under
        // you. Read before the rebuild: `currentSession` still indexes the old list here.
        let selected = currentSession?.id
        let filter = sessionFilter
        list = SessionList(filter.isEmpty ? sessions : sessions.filter { session in
            FilterQuery.matches(
                filter,
                [session.title, session.worktreeName, session.branch, session.agent]
                    + session.repos.map(\.name) + session.trackedPRs.map { "#\($0.number)" }
            )
        })
        if let selected, let index = list.ordered.firstIndex(where: { $0.id == selected }) {
            cursor = index
        } else {
            cursor = min(cursor, max(list.ordered.count - 1, 0))
        }
    }

    private func replace(with domain: Domain) {
        sessions = domain.sessions
        layouts = domain.layouts
        repos = domain.repos
        worktrees = domain.worktrees
        history = domain.history
        github = domain.github
        pullDetails = domain.pullDetails
        cursor = min(cursor, max(list.ordered.count - 1, 0))
    }

    /// The one way the domain changes. Only properties that actually changed are written, so only their readers redraw.
    func commit(_ changes: [DomainChange]) {
        guard !changes.isEmpty else { return }
        let before = currentDomain
        let after = before.applying(changes)
        if after.history != before.history { history = after.history }
        if after.github != before.github { github = after.github }
        if after.repos != before.repos || after.github.pulls != before.github.pulls { loadAvatars() }
        if after.pullDetails != before.pullDetails { pullDetails = after.pullDetails }
        if after.sessions != before.sessions { sessions = after.sessions }
        if after.layouts != before.layouts { layouts = after.layouts }
        if after.repos != before.repos { repos = after.repos }
        if after.worktrees != before.worktrees { worktrees = after.worktrees }
        if let store { Task { await store.apply(changes) } }
    }

    func commit(_ change: DomainChange) { commit([change]) }

    var currentDomain: Domain {
        Domain(
            repos: repos, worktrees: worktrees, sessions: sessions, layouts: layouts, history: history, github: github,
            pullDetails: pullDetails
        )
    }

    /// Scans the repo roots and lists every repo's worktrees with their status, concurrently and off the main actor.
    func refreshRepos() async {
        guard !isFixture else { return }
        var found = await RepoScanner.scan(roots: settings.repoRoots)
        for path in settings.repoPaths {
            if let record = await Git.record(at: Paths.expand(path)), !found.contains(record) { found.append(record) }
        }
        commit(found.map { .repoUpserted($0) })
        // Every clone, not one per repo: two checkouts of the same GitHub repo (in ~/Projects and ~/code, say) share
        // one record, and each has worktrees of its own. A repo's list is committed once all its clones answered.
        let known = repos.filter { !found.map(\.path).contains($0.path) }
        let clones = Dictionary(grouping: found + known) { $0.repo }
        await withTaskGroup(of: [DomainChange].self) { group in
            for (repo, records) in clones {
                group.addTask {
                    var listed: [Worktree] = []
                    for record in records {
                        for worktree in await (try? Git.worktrees(of: record)) ?? []
                            where !listed.contains(where: { $0.path == worktree.path })
                        {
                            listed.append(worktree)
                        }
                    }
                    guard !listed.isEmpty else { return [] }
                    for index in listed.indices {
                        listed[index].status = try? await Git.status(at: listed[index].path)
                    }
                    return [.worktreesListed(repo: repo, listed)]
                }
            }
            for await changes in group {
                commit(changes)
            }
        }
    }

    /// `gB` / `gR` with more than one place to go.
    private(set) var linkPicker: LinkPicker?
    /// Titles and states of the issues sessions link to (fetched, not cached on disk).
    private(set) var issueInfo: [IssueRef: IssueInfo] = [:]
    private var issueInfoFetchedAt: [IssueRef: Date] = [:]

    // MARK: Derived

    var currentSession: Session? {
        let ordered = list.ordered
        return ordered.indices.contains(cursor) ? ordered[cursor] : nil
    }

    var currentLayout: SessionLayout? { currentSession.flatMap { layouts[$0.id] } }
    var currentTabs: [PaneTab] { currentLayout?.tabs ?? [] }
    var currentTabIndex: Int { currentLayout?.activeTab ?? 0 }

    var currentTab: PaneTab? {
        let all = currentTabs
        return all.indices.contains(currentTabIndex) ? all[currentTabIndex] : nil
    }

    var blockedCount: Int { sessions.count { $0.state.state == .blocked } }
    var askingCount: Int { sessions.count { $0.state.state == .asking } }

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
        case .sessions:
            guard let session = currentSession else { return nil }
            return TitleContext(
                lead: session.repos.first?.name, main: session.branch,
                detail: session.trackedPRs.first.map { "#\($0.number)" }
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
        case .repos:
            guard worktreeRows.indices.contains(repoCursor) else { return nil }
            let worktree = worktreeRows[repoCursor]
            return TitleContext(lead: worktree.repo.name, main: worktree.branch ?? "detached \(worktree.head)")
        case .history:
            guard let entry = selectedHistory else { return nil }
            return TitleContext(
                lead: entry.session.repos.first?.name,
                main: entry.session.branch,
                detail: entry.session.title
            )
        }
    }

    private func pullContext(_ ref: PullRef) -> TitleContext {
        TitleContext(
            lead: ref.repo.name,
            main: "#\(ref.number)",
            detail: github.pull(ref)?.title ?? pullDetails[ref.description]?.title
        )
    }

    // The Repos view's lists, kept rather than computed on every read: the table reads them per row and per repo.
    /// Added worktrees (not main checkouts), in table order: grouped by repo in `sortedRepos` order, then by path;
    /// narrowed by the Repos `/` filter.
    private(set) var worktreeRows: [Worktree] = []
    /// Repos as Repos lists them: most worktrees first, then by name.
    private(set) var sortedRepos: [RepoRecord] = []
    /// Rows per repo slug in `worktreeRows`.
    private(set) var worktreeRowCounts: [String: Int] = [:]
    /// Every added worktree, whatever the filter.
    private(set) var worktreeCount = 0

    private func rebuildWorktreeRows() {
        let counts = RepoOrder.worktreeCounts(worktrees)
        // One row per repo in the repo list, however many clones it has.
        var seen: Set<Repo> = []
        let unique = repos.filter { seen.insert($0.repo).inserted }
        sortedRepos = RepoOrder.sorted(unique, counts: counts)
        worktreeCount = counts.values.reduce(0, +)
        let rank = Dictionary(sortedRepos.enumerated().map { ($1.id, $0) }) { first, _ in first }
        let filter = filter(for: .repos)
        let added = worktrees.filter { !$0.isMain }
        let roots = settings.pathRoots
        let matching = filter.isEmpty ? added : added.filter { worktree in
            FilterQuery.matches(filter, [
                worktree.repo.slug, worktree.branch ?? "", Paths.split(worktree.path, roots: roots).relative,
                session(for: worktree)?.agent ?? "",
            ])
        }
        worktreeRows = matching.sorted {
            $0.repo.slug == $1.repo.slug ? $0.path < $1.path
                : (rank[$0.repo.slug] ?? .max, $0.repo.slug) < (rank[$1.repo.slug] ?? .max, $1.repo.slug)
        }
        worktreeRowCounts = Dictionary(grouping: worktreeRows, by: \.repo.slug).mapValues(\.count)
    }

    func session(for worktree: Worktree) -> Session? {
        sessions.first { $0.branch == worktree.branch && $0.repos.contains(worktree.repo) }
    }

    /// Rows selected in VISUAL: the range from the anchor to the cursor, plus rows toggled with space.
    var selectedRows: Set<String> {
        let rows = worktreeRows
        var selected = toggledRows
        if mode == .visual, let anchor = visualAnchor, !rows.isEmpty {
            let range = min(anchor, repoCursor) ... max(anchor, repoCursor)
            for index in range where rows.indices.contains(index) {
                selected.insert(rows[index].id)
            }
        }
        return selected
    }

    /// Hint labels for every session row and every pane of the current tab, in that order.
    /// What `f` labels: in Sessions the sessions and the panes; elsewhere the rows of the view's list.
    var hintTargets: [(label: String, target: HintTarget)] {
        let targets: [HintTarget] = switch view {
        case .sessions:
            list.ordered
                .map { HintTarget.session($0.id) } + (currentTab?.tree.panes.map { HintTarget.pane($0.id) } ?? [])
        case .inbox, .issues, .prs: itemIDs(view).indices.map { HintTarget.row(view, $0) }
        case .repos: worktreeRows.indices.map { HintTarget.row(.repos, $0) }
        case .history: historyRows.indices.map { HintTarget.row(.history, $0) }
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
        if importPicker != nil {
            answerImportPicker(stroke)
            return true
        }
        if linkPicker != nil {
            answerLinkPicker(stroke)
            return true
        }
        if pathImport != nil {
            answerPathImport(stroke)
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
        if startWork != nil {
            handleStartWork(stroke)
            return true
        }
        let before = engine.mode
        let outcome = engine.handle(stroke)
        switch outcome {
        case .terminal:
            if var session = currentSession {
                let now = Date()
                if now.timeIntervalSince(session.lastActivity) > 60 {
                    session.lastActivity = now
                    commit(.sessionUpserted(session))
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
        if previous == .visual {
            toggledRows = []
            visualAnchor = nil
        }
        if mode == .visual {
            visualAnchor = switch view {
            case .repos: repoCursor
            case .inbox, .issues, .prs: itemCursor[view] ?? 0
            default: nil
            }
        }
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
        case "session.attention":
            view = .sessions
            if let next = list.nextNeedingYou(after: cursor) { setCursor(next) } else { flash = "nobody needs you" }
        case "session.pin": togglePin()
        case "session.park": updateCurrent { $0.parked.toggle() }
        case "session.close": confirmClose()
        case "session.delete": confirmDelete()
        case "session.import.path": openPathImport()
        case "session.import":
            if command.arguments.isEmpty {
                openImportPicker()
            } else {
                importPath(command.arguments.joined(separator: " "))
            }
        case "session.back": goBack()
        case "pin.jump": jumpToPin(Int(command.arguments.first ?? "") ?? 1)
        case "work.start" where command.arguments.first == "--agent":
            // `:agent claude`: Start work with that agent chosen.
            let name = command.arguments.dropFirst().first ?? ""
            openStartWork(prompt: "")
            if startWork?.choose(agent: name) == false {
                flash = "no agent \(name) (\(settings.agents.map(\.name).joined(separator: ", ")))"
            }
        case "work.start": openStartWork(prompt: command.arguments.joined(separator: " "))
        case "resume": Task { await offerResume(domain: currentDomain, asked: true) }
        case "session.open": openSession(matching: command.arguments.joined(separator: " "))
        case "tab.go":
            if let n = command.arguments.first.flatMap(Int.init) ?? command.count, currentTabs.indices.contains(n - 1) {
                selectTab(n - 1)
            } else {
                flash = "no tab \(command.arguments.first ?? "") (this session has \(currentTabs.count))"
            }
        case "filter.clear":
            filtering = false
            clearFilter(view)
        case "issues.repo": pickIssueRepo(named: command.arguments.first)
        case "app.activate": activateHeed()
        case "pr.track": trackPull(command.arguments.first)
        case "pr.untrack": untrackPull(command.arguments.first)
        case "select.pin": pinSelected()
        case "work.again": openStartWork(prompt: currentSession?.prompt ?? "")
        case "worktree.new":
            openStartWork(prompt: "")
            if worktreeRows.indices.contains(repoCursor) {
                let row = worktreeRows[repoCursor]
                startWork?.choose(repo: row.repo.slug)
            }
        case "repo.scan": rescan()
        case "repo.add": addRepo(command.arguments.joined(separator: " "))
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
        case "view": if let target = AppView(rawValue: command.arguments.first ?? "") { view = target }
        case "view.history": view = .history
        case "view.repos": view = .repos
        case "view.sessions": view = .sessions
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
            if command.name == "mode.insert", view != .sessions || currentTab == nil { engine.enter(.normal) }
            hintThenInsert = false
        case "hint.insert":
            engine.enter(.hint)
            hintThenInsert = true
        case "command.submit": submitCommandLine()
        case "command.complete": completeCommandLine()
        case "select.toggle": toggleRow()
        case "select.copy": copySelectedPaths()
        case "select.open": openSelected()
        case "select.remove": confirmRemoveSelected()
        case "session.filter": startFilter()
        case "github.sync": Task { await syncGitHub() }
        case "items.start": startFromItems()
        case "items.add": addItemsToSession()
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
        case "issues.visibility": toggleIssueVisibility()
        case "open.reader": openReader()
        case "open.browser": openInBrowser()
        case "open.repo": openRepo()
        case "links.pick": pickLinks()
        case "issue.add": addIssue(command.arguments.first)
        case "issue.remove": removeIssue(command.arguments.first)
        case "overlay.pr": togglePullOverlay()
        case "overlay.item": toggleItemOverlay()
        case "pr.next": cyclePull(by: 1)
        case "pr.prev": cyclePull(by: -1)
        case "jump.back": closeReaderOrOverlay()
        case "pr.start": startFromPull()
        case "pr.session": jumpToPullSession()
        case "history.reopen": reopenSelected()
        case "history.again": openStartWork(prompt: selectedHistory?.session.prompt ?? "")
        case "history.outcome": cycleOutcome()
        case "app.quit": NSApp.terminate(nil)
        case "config.edit": NSWorkspace.shared.open(configFile)
        case "tools.detect": Task { await detectTools(force: true) }
        case "settings.open":
            if let name = command.arguments.first {
                guard let section = SettingsView.Section.named(name) else {
                    flash = "no Settings section \(name) (general, agents, colors, cleanup, keys)"
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

    /// `<Esc>` in NORMAL: the reader, an overlay, then back from a view to Sessions.
    private func closeTopmost() {
        if issueReader != nil {
            issueReader = nil
        } else if reader != nil {
            reader = nil
        } else if overlay != nil {
            overlay = nil
        }
        // Never a view change: views are places of their own, not layers over Sessions.
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
        case .repos: setRow(repoCursor + delta)
        case .history: setRow(historyCursor + delta)
        case .inbox, .issues, .prs: setRow((itemCursor[view] ?? 0) + delta)
        case .sessions: setCursor(cursor + delta)
        }
    }

    /// The current list's group of each row, and the cursor: sidebar groups, repos, days.
    private var rowGroups: (keys: [String], cursor: Int) {
        switch view {
        case .sessions: (list.ordered.map { sessionGroup($0).rawValue }, cursor)
        case .repos: (worktreeRows.map(\.repo.slug), repoCursor)
        case .inbox: (inboxRows.map(\.repo.slug), cursor(in: .inbox))
        case .issues: (issueRows.map(\.repo.slug), cursor(in: .issues))
        case .prs: (pullRows.map(\.ref.repo.slug), cursor(in: .prs))
        case .history:
            (historyRows.map { Calendar.current.startOfDay(for: $0.closedAt).description }, historyCursor)
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
        } else if view == .history {
            let count = historyRows.count
            guard count > 0 else { return }
            historyCursor = min(max(index, 0), count - 1)
        } else if view == .repos {
            let count = worktreeRows.count
            guard count > 0 else { return }
            repoCursor = min(max(index, 0), count - 1)
        } else {
            setCursor(index)
        }
    }

    private func setCursor(_ index: Int) {
        let count = list.ordered.count
        guard count > 0 else { return }
        let clamped = min(max(index, 0), count - 1)
        if clamped != cursor { previousSessionID = currentSession?.id }
        cursor = clamped
    }

    private func select(sessionID: String) {
        if let index = list.ordered.firstIndex(where: { $0.id == sessionID }) { setCursor(index) }
    }

    private func goBack() {
        guard let previous = previousSessionID else { return }
        select(sessionID: previous)
    }

    private func jumpToPin(_ number: Int) {
        let pins = list.pins
        guard pins.indices.contains(number - 1) else {
            flash = "no pinned session \(number)"
            return
        }
        view = .sessions
        select(sessionID: pins[number - 1].id)
    }

    private func togglePin() {
        guard let session = currentSession else { return }
        if !session.pinned, list.pins.count >= SessionGroup.maxPins {
            flash = "already \(SessionGroup.maxPins) pins; unpin one first"
            return
        }
        updateCurrent { $0.pinned.toggle() }
    }

    /// Edits the current session and keeps the cursor on it, even when the edit moves it to another group.
    private func updateCurrent(_ edit: (inout Session) -> Void) {
        guard var session = currentSession else { return }
        edit(&session)
        commit(.sessionUpserted(session))
        select(sessionID: session.id)
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
        let running = sessions.count { [.working, .blocked, .asking].contains($0.state.state) }
        ask(Confirmation(
            title: "Stop every agent?",
            lines: [
                running > 0 ? "\(running) agent\(running == 1 ? " is" : "s are") working and will stop" :
                    "Agents and shells in every pane stop",
                "Sessions stay; their panes reopen as shells, and resume works as after a restart",
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
        let running = sessions.filter { [.working, .blocked, .asking].contains($0.state.state) }
        guard !running.isEmpty, confirmation == nil else { return confirmation != nil }
        activateHeed()
        ask(Confirmation(
            title: "Quit Heed?",
            lines: ["\(running.count) agent\(running.count == 1 ? " is" : "s are") running and will stop"]
                + running.prefix(5).map { "\($0.title) · \($0.state.state.rawValue)" }
                + (running.count > 5 ? ["and \(running.count - 5) more"] : [])
                + ["Sessions stay and can resume on the next launch"],
            accept: "Quit"
        ) { [weak self] in
            self?.quitConfirmed = true
            NSApp.terminate(nil)
        })
        return true
    }

    private func confirmClose() {
        guard let session = currentSession else { return }
        let running = [.working, .blocked, .asking].contains(session.state.state)
        ask(Confirmation(
            title: "Close \(session.title)?",
            lines: [
                running ? "\(session.agent) is \(session.state.state.rawValue): it stops with the panes" :
                    "Its panes close",
                "The worktree stays; the session moves to History, where R reopens it",
            ],
            accept: "Close"
        ) { [weak self] in self?.closeCurrent() })
    }

    /// `dd` in Sessions: the session and its worktrees. Worktrees with unsaved work are kept (and said so).
    private func confirmDelete() {
        guard let session = currentSession else { return }
        let (removals, kept, lines) = deletion(of: session)
        ask(Confirmation(
            title: "Delete \(session.title)?",
            lines: ["The agent and its panes stop; the session moves to History"] + lines,
            kept: kept,
            accept: "Delete"
        ) { [weak self] in self?.deleteSession(session.id, removals: removals, kept: kept) })
    }

    /// What deleting a session removes: its worktrees, minus those with work not saved anywhere else.
    private func deletion(of session: Session) -> ([WorktreeRemoval], [String], [String]) {
        let mine = worktrees.filter { !$0.isMain && session.owns($0) }
        let (removals, kept) = planRemoval(mine, sessionsFollow: false)
        let lines = removals.map { removal in
            "remove \(removal.worktree.repo.name)/\(removal.worktree.branch ?? "")"
                + (removal.deleteBranch ? " and its local branch" : "")
        } + (mine.isEmpty ? ["No worktree to remove"] : [])
        return (removals, kept, lines)
    }

    private func deleteSession(_ id: String, removals: [WorktreeRemoval], kept: [String]) {
        closeSession(id)
        if !removals.isEmpty { removeWorktrees(removals, kept: kept) }
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
            lines: ["The agent in it stops; the session and its worktree stay"],
            accept: "Close"
        ) { [weak self] in self?.closePane() })
    }

    private func closeCurrent() {
        guard let session = currentSession else { return }
        closeSession(session.id)
    }

    /// A session to History, its panes closed; its worktree stays.
    private func closeSession(_ id: String) {
        guard var session = sessions.first(where: { $0.id == id }) else { return }
        let minutes = Int(Date().timeIntervalSince(session.createdAt) / 60)
        session.record("ended after \(minutes / 60)h \(minutes % 60)m")
        // The panes are read before the close drops the layout.
        let panes = layouts[id]?.tabs.flatMap(\.tree.panes) ?? []
        commit(.sessionClosed(HistoryEntry(
            session: session, closedAt: Date(), outcome: HistoryEntry.outcome(closing: session)
        )))
        for pane in panes {
            TerminalSurfaces.shared.close(paneID: pane.id)
        }
        cursor = min(cursor, max(list.ordered.count - 1, 0))
        flash = "closed; worktree kept · in history (gh)"
    }

    private func jump(to target: HintTarget) {
        let thenInsert = hintThenInsert
        hintThenInsert = false
        hintText = ""
        switch target {
        case let .session(id):
            select(sessionID: id)
            engine.enter(.normal)
        case let .pane(id):
            updateTab { $0.focused = id }
            engine.enter(thenInsert ? .insert : .normal)
            if thenInsert { terminalFocusRequest += 1 }
        case let .row(view, index):
            // f moves the cursor there; F also opens it.
            engine.enter(.normal)
            switch view {
            case .repos:
                repoCursor = index
                if thenInsert { openSelected() }
            case .history:
                historyCursor = index
            default:
                itemCursor[view] = index
                if thenInsert { openReader() }
            }
        }
    }

    // MARK: Repos view

    private func toggleRow() {
        if [.inbox, .issues, .prs].contains(view) {
            let ids = itemIDs(view)
            let index = itemCursor[view] ?? 0
            guard ids.indices.contains(index) else { return }
            if picked[view, default: []].contains(ids[index]) {
                picked[view]?.remove(ids[index])
            } else {
                picked[view, default: []].insert(ids[index])
            }
            return
        }
        let rows = worktreeRows
        guard view == .repos, rows.indices.contains(repoCursor) else { return }
        let id = rows[repoCursor].id
        if toggledRows.contains(id) { toggledRows.remove(id) } else { toggledRows.insert(id) }
    }

    private var actionRows: [Worktree] {
        let rows = worktreeRows
        let selected = selectedRows
        if !selected.isEmpty { return rows.filter { selected.contains($0.id) } }
        return rows.indices.contains(repoCursor) ? [rows[repoCursor]] : []
    }

    private func copySelectedPaths() {
        let paths = actionRows.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        flash = "copied \(paths.count) path\(paths.count == 1 ? "" : "s")"
        engine.enter(.normal)
        modeChanged(from: .visual)
    }

    /// `↩` in Repos (`o` in VISUAL): a worktree with a session jumps to it; ones without are imported as sessions,
    /// resuming the agent session kept there when there is one. Asks first, showing what each will resume.
    private func openSelected() {
        let rows = actionRows
        if mode == .visual {
            engine.enter(.normal)
            modeChanged(from: .visual)
        }
        openOrImport(rows)
    }

    // MARK: Import picker

    /// `I` in Sessions: pick a worktree without a session (main checkouts included) to import.
    private(set) var importPicker: Typeahead<Worktree>?

    // MARK: Import a path

    /// `P` in Sessions: a path typed with directory completion, previewed as it changes, imported with ↩.
    struct PathImport {
        var query: String
        /// Directories completing the query; the cursor picks one for ⇥.
        var candidates: [String] = []
        var cursor = 0
        /// What is at the query: "nullean/curb · fix/x", or why nothing can be imported there.
        var preview: String?
        var importable = false
    }

    private(set) var pathImport: PathImport?
    private var pathPreviewTask: Task<Void, Never>?

    private func openPathImport() {
        pathImport = PathImport(query: "~/")
        refreshPathImport()
    }

    func cancelPathImport() { pathImport = nil }

    private func answerPathImport(_ stroke: KeyStroke) {
        guard var state = pathImport else { return }
        switch stroke {
        case .escape:
            pathImport = nil
            return
        case KeyStroke("CR"):
            pathImport = nil
            importPath(state.query)
            return
        case KeyStroke("Tab"):
            // Complete to the highlighted directory, ready for the next component.
            // The list may still be on its way after fast typing; one folder listing now is cheap.
            let candidates = state.candidates.isEmpty ? PathCompletion.candidates(for: state.query) : state.candidates
            guard candidates.indices.contains(state.cursor) else { return }
            state.query = Paths.abbreviate(candidates[state.cursor]) + "/"
        case KeyStroke("n", .control), KeyStroke("j", .control), KeyStroke("Down"):
            state.cursor = min(state.cursor + 1, max(state.candidates.count - 1, 0))
            pathImport = state
            return
        case KeyStroke("p", .control), KeyStroke("k", .control), KeyStroke("Up"):
            state.cursor = max(state.cursor - 1, 0)
            pathImport = state
            return
        case KeyStroke("BS"):
            if !state.query.isEmpty { state.query.removeLast() }
        case KeyStroke("w", .control), KeyStroke("BS", .option):
            state.query = PathCompletion.droppingLastComponent(state.query)
        case KeyStroke("u", .control):
            state.query = ""
        case KeyStroke("Space"):
            state.query += " "
        default:
            guard !stroke.isNamed, stroke.modifiers.subtracting(.option).isEmpty else { return }
            state.query += stroke.key
        }
        state.cursor = 0
        pathImport = state
        refreshPathImport()
    }

    /// Completions and the preview, off the main actor; a newer keystroke cancels an older lookup.
    private func refreshPathImport() {
        guard let query = pathImport?.query else { return }
        if ShotMode.active {
            // Screenshots never read the real disk: a made-up tree under /Users/you.
            let folders = [
                "/Users/you/code/wt/docs-builder",
                "/Users/you/code/wt/mermaider",
                "/Users/you/Projects/sandbox",
            ]
            updatePathImport(query) {
                let typed = query.replacingOccurrences(of: "~", with: "/Users/you")
                $0.candidates = folders.filter { $0.hasPrefix(typed) && $0 != typed.trimmingCharacters(in: ["/"]) }
                $0.preview = query.contains("toc") ? "elastic/docs-builder · toc-ordering" : nil
                $0.importable = query.contains("toc")
            }
            return
        }
        pathPreviewTask?.cancel()
        pathPreviewTask = Task { [weak self] in
            let candidates = await Task.detached { PathCompletion.candidates(for: query) }.value
            guard !Task.isCancelled else { return }
            self?.updatePathImport(query) { $0.candidates = candidates }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let path = Paths.expand(query)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                self?.updatePathImport(query) {
                    $0.preview = query.isEmpty ? nil : "no such folder"
                    $0.importable = false
                }
                return
            }
            let found = await Git.locate(path)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard let found else {
                updatePathImport(query) {
                    $0.preview = "not inside a git worktree"
                    $0.importable = false
                }
                return
            }
            let name = "\(found.record.repo.slug) · \(found.worktree.branch ?? "detached")"
                + (found.worktree.isMain ? " (main checkout)" : "")
            let hasSession = worktrees.first { $0.path == found.worktree.path }.flatMap { session(for: $0) } != nil
            updatePathImport(query) {
                $0.preview = hasSession ? "\(name): has a session, ↩ jumps to it" : name
                $0.importable = true
            }
        }
    }

    private func updatePathImport(_ query: String, _ edit: (inout PathImport) -> Void) {
        guard var state = pathImport, state.query == query else { return }
        edit(&state)
        pathImport = state
    }

    static func looksLikePath(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("~")
    }

    /// Imports the worktree at `path` (any worktree of any repo): the repo is added if Heed did not know it (and kept
    /// in `[worktrees] repo_paths` when it lies outside the scanned roots), then the worktree imports like any other.
    func importPath(_ raw: String) {
        let path = Paths.expand(raw.trimmingCharacters(in: .whitespaces))
        guard !isFixture else {
            flash = "fixture: no IO"
            return
        }
        flash = "looking at \(Paths.abbreviate(path))…"
        Task {
            guard let (worktree, listed) = await adoptRepo(at: path) else { return }
            openOrImport([listed.first { $0.path == worktree.path } ?? worktree])
        }
    }

    /// `:repo.add <path>`: the repo at `path` joins Repos with its worktrees, and is kept in `[worktrees] repo_paths`
    /// when it lies outside the scanned roots.
    private func addRepo(_ raw: String) {
        let path = Paths.expand(raw.trimmingCharacters(in: .whitespaces))
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            flash = ":repo.add <path> adds a repo outside \(settings.repoRoots.joined(separator: ", "))"
            return
        }
        guard !isFixture else {
            flash = "fixture: no IO"
            return
        }
        flash = "looking at \(Paths.abbreviate(path))…"
        Task {
            guard let (worktree, listed) = await adoptRepo(at: path) else { return }
            view = .repos
            flash = "added \(worktree.repo.slug): \(listed.count) worktree\(listed.count == 1 ? "" : "s")"
        }
    }

    /// The repo and worktrees at `path`, made known: added to the domain (and to repo_paths if outside the roots).
    private func adoptRepo(at path: String) async -> (worktree: Worktree, listed: [Worktree])? {
        guard let found = await Git.locate(path) else {
            flash = "not inside a git worktree: \(Paths.abbreviate(path))"
            return nil
        }
        if !repos.contains(where: { $0.id == found.record.id }) {
            commit(.repoUpserted(found.record))
            let roots = settings.repoRoots.map { Paths.expand($0) }
            if !roots.contains(where: { found.record.path.hasPrefix($0 + "/") }) {
                setConfig(
                    ["worktrees", "repo_paths"],
                    .array((settings.repoPaths + [Paths.abbreviate(found.record.path)]).map { .string($0) })
                )
            }
        }
        var listed = found.all
        for index in listed.indices {
            listed[index].status = try? await Git.status(at: listed[index].path)
        }
        commit(.worktreesListed(repo: found.record.repo, listed))
        return (found.worktree, listed)
    }

    private func openImportPicker() {
        let rank = Dictionary(sortedRepos.enumerated().map { ($1.id, $0) }) { first, _ in first }
        let candidates = worktrees.filter { session(for: $0) == nil }.sorted {
            if $0.isMain != $1.isMain { return !$0.isMain }
            return $0.repo.slug == $1.repo.slug ? $0.path < $1.path
                : (rank[$0.repo.slug] ?? .max, $0.repo.slug) < (rank[$1.repo.slug] ?? .max, $1.repo.slug)
        }
        // Open even when every listed worktree has a session: a typed path imports any other.
        // The path below its root, so a root's own words (code, Projects) do not match every worktree.
        let roots = settings.pathRoots
        importPicker = Typeahead(items: candidates) {
            [$0.repo.slug, $0.branch ?? "", Paths.split($0.path, roots: roots).relative]
        }
    }

    private func answerImportPicker(_ stroke: KeyStroke) {
        guard var picker = importPicker else { return }
        // A typed path imports whatever worktree is there, known or not.
        if stroke == KeyStroke("CR"), Self.looksLikePath(picker.query), picker.matches.isEmpty {
            importPicker = nil
            importPath(picker.query)
            return
        }
        switch picker.handle(stroke) {
        case .handled: importPicker = picker
        case .cancel: importPicker = nil
        case let .picked(worktree):
            importPicker = nil
            openOrImport([worktree])
        }
    }

    func pickImport(_ worktree: Worktree) {
        importPicker = nil
        openOrImport([worktree])
    }

    func cancelImportPicker() { importPicker = nil }

    private func openOrImport(_ rows: [Worktree]) {
        guard !rows.isEmpty else { return }
        let missing = rows.filter { session(for: $0) == nil }
        if missing.isEmpty, let session = session(for: rows[0]) {
            view = .sessions
            select(sessionID: session.id)
            return
        }
        guard !isFixture else {
            flash = "fixture: no IO"
            return
        }
        let defaultAgent = settings.agent(settings.defaultAgent)
        flash = "looking for agent sessions…"
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                missing.map { ($0, Import.claudeSessions(directory: $0.path).first) }
            }.value
            flash = nil
            let lines = found.map { worktree, agentSession -> String in
                let name = "\(worktree.repo.name)/\(worktree.branch ?? worktree.head)"
                guard let agentSession else { return "\(name): starts \(defaultAgent?.name ?? "a shell") fresh" }
                let age = agentSession.modified.formatted(.relative(presentation: .named))
                let prompt = agentSession.prompt.map { " · “\($0.prefix(50))”" } ?? ""
                return "\(name): resumes the claude session from \(age)\(prompt)"
            }
            ask(Confirmation(
                title: found
                    .count == 1 ? "Import this worktree as a session?" : "Import \(found.count) worktrees as sessions?",
                lines: lines,
                accept: "Import",
                destructive: false
            ) { [weak self] in self?.importWorktrees(found, defaultAgent: defaultAgent) })
        }
    }

    private func importWorktrees(_ found: [(Worktree, Import.AgentSession?)], defaultAgent: AgentProfile?) {
        var firstID: String?
        for (worktree, agentSession) in found {
            let agent = agentSession.flatMap { settings.agent($0.agent) } ?? defaultAgent
            let changes = Import.session(for: worktree, agent: agent, resume: agentSession, integration: integration)
            for case let .layoutChanged(_, layout) in changes {
                for pane in layout.tabs.flatMap(\.tree.panes) where pane.command != nil {
                    TerminalSurfaces.shared.autostartPanes.insert(pane.id)
                }
            }
            for case let .sessionUpserted(session) in changes where firstID == nil {
                firstID = session.id
            }
            commit(changes)
        }
        view = .sessions
        if let firstID { select(sessionID: firstID) }
        if let tab = currentTab, let agent = tab.tree.panes.first(where: { $0.role == .agent }) { focusPane(agent.id) }
        enterInsert()
        flash = "imported \(found.count) session\(found.count == 1 ? "" : "s")"
    }

    /// Which of `rows` can go (clean, pushed, not pinned) and why the rest stay.
    private func planRemoval(_ rows: [Worktree], sessionsFollow: Bool = true) -> (
        removals: [WorktreeRemoval], kept: [String]
    ) {
        var kept: [String] = []
        var removals: [WorktreeRemoval] = []
        for worktree in rows {
            let users = sessions.filter { $0.branch == worktree.branch && $0.repos.contains(worktree.repo) }
            if sessionsFollow, users.contains(where: \.pinned) {
                kept.append("\(worktree.repo.name)/\(worktree.branch ?? worktree.path): pinned session")
            } else if let reason = WorktreeRemoval.unsafe(worktree) {
                kept.append("\(worktree.repo.name)/\(worktree.branch ?? worktree.path): \(reason)")
            } else {
                removals.append(WorktreeRemoval(
                    worktree: worktree, sessions: sessionsFollow ? users.map(\.id) : [],
                    deleteBranch: worktree.branch != nil
                ))
            }
        }
        return (removals, kept)
    }

    private func confirmRemoveSelected() {
        let rows = actionRows
        if mode == .visual {
            engine.enter(.normal)
            modeChanged(from: .visual)
        }
        guard !rows.isEmpty else {
            flash = "nothing selected"
            return
        }
        let (removals, kept) = planRemoval(rows)
        guard !removals.isEmpty else {
            flash = "kept: \(kept.joined(separator: "; "))"
            return
        }
        let closing = Set(removals.flatMap(\.sessions)).count
        ask(Confirmation(
            title: removals.count == 1
                ? "Remove \(removals[0].worktree.repo.name)/\(removals[0].worktree.branch ?? "worktree")?"
                : "Remove \(removals.count) worktrees?",
            lines: removals.map { removal in
                "\(removal.worktree.repo.name)/\(removal.worktree.branch ?? removal.worktree.path)"
                    + (removal.deleteBranch ? " · local branch too" : "")
            } +
                (closing > 0 ?
                    ["\(closing) session\(closing == 1 ? "" : "s") on them move\(closing == 1 ? "s" : "") to History"] :
                    []),
            kept: kept,
            accept: "Remove"
        ) { [weak self] in self?.removeWorktrees(removals, kept: kept) })
    }

    private func removeWorktrees(_ removals: [WorktreeRemoval], kept: [String]) {
        guard !isFixture else {
            flash = "fixture: no IO"
            return
        }
        for id in Set(removals.flatMap(\.sessions)) {
            for pane in layouts[id]?.tabs.flatMap(\.tree.panes) ?? [] {
                TerminalSurfaces.shared.close(paneID: pane.id)
            }
        }
        let skipped = kept
        Task {
            let (changes, failures) = await WorktreeRemoval.execute(removals, domain: currentDomain)
            commit(changes)
            flash = "removed \(removals.count - failures.count)" +
                (skipped.isEmpty ? "" : " · kept \(skipped.count): \(skipped[0])")
                + (failures.isEmpty ? "" : " · failed: \(failures[0])")
        }
    }

    private func rescan() {
        guard !isFixture else {
            flash = "fixture: no IO"
            return
        }
        flash = "scanning \(settings.repoRoots.joined(separator: ", "))…"
        Task {
            await refreshRepos()
            flash = "\(repos.count) repos · \(worktreeCount) worktrees"
        }
    }

    // MARK: History

    /// History in display order (newest first), filtered by `/` text and the outcome chip.
    var historyRows: [HistoryEntry] {
        let filter = filter(for: .history)
        return history.filter { entry in
            (historyOutcome == nil || entry.outcome == historyOutcome)
                && FilterQuery.matches(
                    filter,
                    [
                        entry.session.title, entry.session.prompt, entry.session.branch, entry.session.agent,
                    ] + entry.session.repos.map(\.name)
                )
        }
    }

    var selectedHistory: HistoryEntry? {
        let rows = historyRows
        return rows.indices.contains(historyCursor) ? rows[historyCursor] : nil
    }

    private func cycleOutcome() {
        let all: [Outcome?] = [nil] + Outcome.allCases
        let index = all.firstIndex(of: historyOutcome) ?? 0
        historyOutcome = all[(index + 1) % all.count]
        historyCursor = 0
    }

    private func reopenSelected() {
        guard let entry = selectedHistory else { return }
        guard !isFixture else {
            flash = "fixture: no IO"
            return
        }
        let domain = currentDomain
        let settings = settings
        let integration = integration
        flash = "reopening \(entry.session.title)…"
        Task {
            do {
                let changes = try await Reopen.execute(
                    entry,
                    domain: domain,
                    settings: settings,
                    integration: integration
                )
                for case let .layoutChanged(_, layout) in changes {
                    for pane in layout.tabs.flatMap(\.tree.panes) where pane.command != nil {
                        TerminalSurfaces.shared.autostartPanes.insert(pane.id)
                    }
                }
                commit(changes)
                view = .sessions
                select(sessionID: entry.id)
                flash = "reopened \(entry.session.title)"
            } catch {
                flash = "reopen failed: \(error)"
            }
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

    /// Issues the rules show (involving you, or in a repo showing all), narrowed by the chip and the repo column.
    var shownIssues: [Issue] {
        github.issues
            .filter { ($0.involvesYou || config.issues.visibility($0.repo) == .all) && issueFilter.matches($0) }
    }

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

    /// `:session.open anchors`: the first session matching every word, as the filter matches.
    private func openSession(matching words: String) {
        guard !words.isEmpty else {
            flash = ":session.open <words> goes to the first session matching them"
            return
        }
        guard let session = list.ordered.first(where: { session in
            FilterQuery.matches(words, [session.title, session.branch, session.agent] + session.repos.map(\.name))
        }) else {
            flash = "no session matches \(words)"
            return
        }
        view = .sessions
        select(sessionID: session.id)
    }

    /// `gU` (`:track <url>`): the current session tracks that PR; with no URL, the one on the clipboard.
    /// `:pr.untrack [url]`: the session stops following a PR (the one in the overlay, or the session's only one), and
    /// no rule adds it back.
    private func untrackPull(_ argument: String?) {
        guard let session = currentSession else { return flash = "no session here" }
        let pull = argument.flatMap(PullRef.init(url:)) ?? shownPull
            ?? (session.trackedPRs.count == 1 ? session.trackedPRs.first : nil)
        guard let pull, session.trackedPRs.contains(pull) else {
            return flash = session.trackedPRs.isEmpty ? "this session tracks no PR"
                : "which PR? :pr.untrack <url>, or open it (go) first"
        }
        updateCurrent { session in
            session.trackedPRs.removeAll { $0 == pull }
            session.untrackedPRs.append(pull)
            session.record("stopped tracking PR \(pull.repo.name)#\(pull.number) (by you)")
        }
        flash = "stopped tracking \(pull.repo.name)#\(pull.number); :pr.track adds it back"
    }

    /// After a PR's detail arrives: the sessions tracking it also take the PRs that link to it and are yours, opened
    /// since the session started (a follow-up, a companion change in another repo).
    private func trackLinked(_ detail: PullDetail) {
        guard let references = detail.references, !references.isEmpty else { return }
        let changes = sessions.filter { $0.trackedPRs.contains(detail.ref) }.compactMap { session -> DomainChange? in
            var updated = session
            let added = PullTracking.linked(references, session: session, viewer: github.viewer).track
                .filter { updated.track($0.ref, because: "links to \(detail.ref.repo.name)#\(detail.ref.number)") }
            return added.isEmpty ? nil : .sessionUpserted(updated)
        }
        commit(changes)
        for case let .sessionUpserted(session) in changes {
            for ref in session.trackedPRs where pullDetails[ref.description] == nil {
                fetchDetail(ref)
            }
        }
    }

    /// PRs that mention this one but are someone else's (or older than the session): shown, not tracked.
    func suggestedLinks(for ref: PullRef) -> [PullDetail.Reference] {
        guard let references = pullDetails[ref.description]?.references,
              let session = sessions.first(where: { $0.trackedPRs.contains(ref) })
        else { return [] }
        return PullTracking.linked(references, session: session, viewer: github.viewer).suggest
    }

    private func trackPull(_ argument: String?) {
        let text = argument ?? NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let pull = PullRef(url: text) else {
            flash = argument == nil ? "copy a PR URL first, or :track <url>" : "not a PR URL: \(text)"
            return
        }
        guard currentSession != nil else {
            flash = "no session to track \(pull.repo.name)#\(pull.number)"
            return
        }
        guard currentSession?.trackedPRs.contains(pull) == false else {
            flash = "already tracking \(pull.repo.name)#\(pull.number)"
            return
        }
        updateCurrent { session in
            session.untrackedPRs.removeAll { $0 == pull }
            session.track(pull, because: "by you")
        }
        flash = "tracking \(pull.repo.name)#\(pull.number)"
        if !isFixture { Task { await syncGitHub(parts: [.pulls]) } }
    }

    /// VISUAL `m` in Repos: pins the sessions on the selected worktrees; when all are pinned already, unpins them.
    private func pinSelected() {
        let targets = actionRows.compactMap(session(for:))
        if mode == .visual {
            engine.enter(.normal)
            modeChanged(from: .visual)
        }
        guard !targets.isEmpty else {
            flash = "no sessions on the selected worktrees"
            return
        }
        let pin = !targets.allSatisfy(\.pinned)
        let room = SessionGroup.maxPins - list.pins.count
        let changing = targets.filter { $0.pinned != pin }
        guard !pin || changing.count <= room else {
            flash = "only \(room) pin\(room == 1 ? "" : "s") left of \(SessionGroup.maxPins)"
            return
        }
        commit(changing.map { session in
            var session = session
            session.pinned = pin
            return .sessionUpserted(session)
        })
        flash = "\(pin ? "pinned" : "unpinned") \(changing.count) session\(changing.count == 1 ? "" : "s")"
    }

    func pickIssueRepo(_ repo: Repo?) {
        issueRepo = repo
        itemCursor[.issues] = 0
    }

    /// `w` in Issues, `I` in Repos: the repo under the cursor flips between all issues and only yours.
    private func toggleIssueVisibility() {
        let repo: Repo?
        switch view {
        case .issues:
            let rows = issueRows
            let index = cursor(in: .issues)
            repo = rows.indices.contains(index) ? rows[index].repo : issueRepo
        case .repos:
            let rows = worktreeRows
            repo = rows.indices.contains(repoCursor) ? rows[repoCursor].repo : nil
        default: repo = nil
        }
        guard let repo else {
            flash = "no repo under the cursor"
            return
        }
        let next: IssueVisibility = config.issues.visibility(repo) == .all ? .involved : .all
        if isFixture {
            config.issues.repos[repo.slug] = next
        } else {
            setConfig(["repos", repo.slug, "issues"], .string(next.rawValue))
        }
        flash = next == .all ? "\(repo.name): all open issues" : "\(repo.name): only issues involving you"
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

    private func startFromItems() {
        let prompt = itemsPrompt
        guard !prompt.isEmpty else { return }
        clearPicks()
        issueReader = nil
        openStartWork(prompt: prompt)
    }

    private func addItemsToSession() {
        let prompt = itemsPrompt
        guard !prompt.isEmpty, let session = currentSession, let layout = layouts[session.id],
              let (_, paneID) = agentPane(in: layout)
        else {
            flash = "no session to add to"
            return
        }
        guard session.state.state != .blocked, session.state.state != .asking else {
            flash = "\(session.title) is waiting on you; answer it first"
            return
        }
        TerminalSurfaces.shared.typeLine(prompt.replacingOccurrences(of: "\n", with: " "), paneID: paneID)
        clearPicks()
        flash = "added to \(session.title)"
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
        case .sessions: return currentSession?.trackedPRs.first?.url
        default: return nil
        }
    }

    /// `gB`: what is under the cursor. In Sessions (outside the overlay and reader) the session's links: one opens,
    /// several offer the picker, none opens its repo.
    private func openInBrowser() {
        if view == .sessions, issueReader == nil, shownPull == nil, let session = currentSession {
            let links = links(of: session)
            switch links.count {
            case 0: return openRepo()
            case 1: return open(links[0], browser: true)
            default: linkPicker = LinkPicker(title: "Open in the browser", links: links)
            }
            return
        }
        guard let text = urlUnderCursor, let url = URL(string: text) else {
            flash = "nothing to open"
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: Links

    /// A session's issues: added by hand, closed by its prompt, closed by its PRs.
    func issues(of session: Session) -> [IssueRef] {
        let closedByPulls = session.trackedPRs.flatMap { ref in
            (pullDetails[ref.description]?.closes ?? []).map { IssueRef(repo: $0.repo, number: $0.number) }
        }
        return IssueLinks.issues(
            added: session.issues, prompt: session.prompt, defaultRepo: session.repos.first,
            closedByPulls: closedByPulls, hidden: session.hiddenIssues
        )
    }

    /// Everything a session links to on GitHub, in the inspector's order: open PRs, merged, closed, then issues.
    func links(of session: Session) -> [SessionLink] {
        IssueLinks.ordered(
            pulls: session.trackedPRs, state: { self.github.pull($0)?.state }, issues: issues(of: session),
            closed: { self.issueInfo[$0]?.closed ?? false }
        )
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

    /// A link clicked or picked: a PR opens the overlay on it, an issue the reader; `browser` (⌘-click, `gB`) opens it
    /// on GitHub instead.
    func open(_ link: SessionLink, browser: Bool = false) {
        linkPicker = nil
        if browser {
            if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
            return
        }
        switch link {
        case let .pull(ref):
            if let index = list.ordered.firstIndex(where: { $0.trackedPRs.contains(ref) }), view == .sessions {
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

    /// The repos under the cursor, for `gR`: a session's (all of them), a Repos row's, an item's.
    private var reposUnderCursor: [Repo] {
        if let issue = issueReader { return [issue.repo] }
        if let ref = shownPull, overlay == .pr || reader != nil { return [ref.repo] }
        let index = cursor(in: view)
        switch view {
        case .sessions: return currentSession?.involvedRepos ?? []
        case .repos: return worktreeRows.indices.contains(repoCursor) ? [worktreeRows[repoCursor].repo] : []
        case .inbox: return inboxRows.indices.contains(index) ? [inboxRows[index].repo] : []
        case .issues: return issueRows.indices.contains(index) ? [issueRows[index].repo] : []
        case .prs: return pullRows.indices.contains(index) ? [pullRows[index].ref.repo] : []
        case .history: return selectedHistory?.session.repos ?? []
        }
    }

    /// `gR`: the repo under the cursor on GitHub; a session in several repos offers the picker.
    private func openRepo() {
        let repos = reposUnderCursor.filter { $0.org != "local" }
        switch repos.count {
        case 0: flash = "no repo here"
        case 1: open(.repo(repos[0]), browser: true)
        default: linkPicker = LinkPicker(title: "Open a repo", links: repos.map(SessionLink.repo))
        }
    }

    /// `:links.pick`: the picker over the session's links (and its repos when it has none).
    private func pickLinks() {
        guard let session = currentSession else { return flash = "no session here" }
        let links = links(of: session)
        linkPicker = LinkPicker(
            title: "Open in the browser", links: links.isEmpty ? session.involvedRepos.map(SessionLink.repo) : links
        )
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

    /// `:issue.add <url>` (or the copied URL): links an issue to the session.
    private func addIssue(_ argument: String?) {
        let text = argument ?? NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let ref = IssueRef(url: text) else {
            return flash = argument == nil ? "copy an issue URL first, or :issue.add <url>" : "not an issue URL: \(text)"
        }
        guard currentSession != nil else { return flash = "no session to link \(ref.repo.name)#\(ref.number) to" }
        updateCurrent { session in
            session.hiddenIssues.removeAll { $0 == ref }
            if !session.issues.contains(ref) { session.issues.append(ref) }
        }
        flash = "linked \(ref.repo.name)#\(ref.number)"
        Task { await refreshIssueInfo(force: [ref]) }
    }

    /// `:issue.remove [url]`: takes an issue off the session (the given one, else its first).
    private func removeIssue(_ argument: String?) {
        guard let session = currentSession else { return }
        guard let ref = argument.flatMap(IssueRef.init(url:)) ?? issues(of: session).first else {
            return flash = "no issue on this session"
        }
        updateCurrent { session in
            session.issues.removeAll { $0 == ref }
            if !session.hiddenIssues.contains(ref) { session.hiddenIssues.append(ref) }
        }
        flash = "unlinked \(ref.repo.name)#\(ref.number)"
    }

    /// Fetches titles and states for the issues sessions link to: those not seen in ten minutes, and `force`.
    func refreshIssueInfo(force: [IssueRef] = []) async {
        guard !isFixture else { return }
        let now = Date()
        let wanted = Set(sessions.flatMap(issues(of:))).filter { ref in
            now.timeIntervalSince(issueInfoFetchedAt[ref] ?? .distantPast) > 600
        }.union(force)
        guard !wanted.isEmpty, let fetched = try? await GitHub.issueInfo(Array(wanted)) else { return }
        for ref in wanted {
            issueInfoFetchedAt[ref] = now
        }
        issueInfo.merge(fetched) { _, new in new }
    }

    private func jumpToPullSession() {
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
        if let session = sessions.first(where: { $0.trackedPRs.contains(ref) }) {
            view = .sessions
            select(sessionID: session.id)
        } else {
            flash = "no session tracks \(ref)"
        }
    }

    // MARK: PR overlay and reader

    /// The PR the overlay or reader is about.
    var shownPull: PullRef? { reader ?? (overlay == .pr ? overlayPull : nil) }

    /// The PR under the cursor where `o` was pressed: a PRs row, a PR in the inbox, or the session's first PR.
    private var pullUnderCursor: PullRef? {
        let index = cursor(in: view)
        switch view {
        case .prs: return pullRows.indices.contains(index) ? pullRows[index].ref : nil
        case .inbox:
            guard inboxRows.indices.contains(index), inboxRows[index].kind == .pr,
                  let number = inboxRows[index].number else { return nil }
            return PullRef(repo: inboxRows[index].repo, number: number)
        case .sessions: return currentSession?.trackedPRs.first
        default: return nil
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

    /// `go`: the PR or issue under the cursor, or in Sessions the session's PR overlay; again closes it.
    private func toggleItemOverlay() {
        if issueReader != nil || reader != nil {
            closeReaderOrOverlay()
        } else if view == .sessions {
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
        guard let first = currentSession?.trackedPRs.first else {
            flash = "this session tracks no PR yet"
            return
        }
        overlayPull = overlayPull.flatMap { currentSession?.trackedPRs.contains($0) == true ? $0 : nil } ?? first
        overlay = .pr
        if let ref = overlayPull { fetchDetail(ref) }
    }

    private func cyclePull(by delta: Int) {
        guard overlay == .pr, let prs = currentSession?.trackedPRs, !prs.isEmpty else { return }
        let index = overlayPull.flatMap { prs.firstIndex(of: $0) } ?? 0
        overlayPull = prs[((index + delta) % prs.count + prs.count) % prs.count]
        if let ref = overlayPull { fetchDetail(ref) }
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

    /// `S`: a new session on the PR, its prompt naming the open review threads and failing checks.
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
        openStartWork(prompt: prompt)
    }

    /// Fetches a PR's detail off the main actor. Reports checks that went from failing to passing.
    func fetchDetail(_ ref: PullRef) {
        guard !isFixture else { return }
        Task {
            guard let detail = try? await GitHub.pullDetail(ref) else { return }
            let failedBefore = pullDetails[ref.description]?.failingChecks.map(\.name) ?? []
            commit(.pullDetailFetched(detail))
            trackLinked(detail)
            let fixed = failedBefore.filter { name in
                !detail.failingChecks.contains { $0.name == name } && !detail.checks.pendingNames.contains(name)
            }
            if !fixed.isEmpty { flash = "\(fixed.joined(separator: ", ")) passing now on #\(ref.number)" }
        }
    }

    /// Details for the PRs active sessions track: the one on screen every time, the others only when the last sync
    /// says their checks or threads moved, or every fifth poll.
    private func refreshTrackedDetails() {
        let open = [overlay == .pr ? overlayPull : nil, reader].compactMap(\.self)
        let now = Date()
        let refs = Set(sessions.flatMap(\.trackedPRs)).filter { ref in
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

    /// The most urgent state among a session's PRs, for its sidebar row.
    func pullStatus(of session: Session) -> PullStatus? {
        session.trackedPRs.map(pullStatus(for:)).min { $0.urgency < $1.urgency }
    }

    /// The group a session is shown in.
    func sessionGroup(_ session: Session) -> SessionGroup {
        list.group(of: session.id) ?? SessionGroup.of(session)
    }

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
        guard currentSession != nil else {
            flash = "no session"
            return
        }
        overlay = .diff
        loadDiff()
    }

    /// Diffs every worktree of the current session (cross-repo sessions show each repo's files), off the main actor.
    private func loadDiff() {
        guard let session = currentSession else { return }
        let targets = worktrees.filter { session.owns($0) }
            .map { worktree in (worktree, repos.first { $0.repo == worktree.repo }?.defaultBranch ?? "main") }
        guard !targets.isEmpty, !isFixture else {
            diffFiles = isFixture ? Fixtures.diff : []
            diffCommits = isFixture ? Fixtures.diffCommits : []
            if !isFixture { flash = "no worktree for \(session.branch) yet" }
            return
        }
        let scope = diffScope
        diffLoading = true
        diffTask?.cancel()
        diffTask = Task {
            defer { diffLoading = false }
            var files: [FileDiff] = []
            for (worktree, base) in targets {
                if let diff = try? await Git.diff(at: worktree.path, scope: scope, base: base, repo: worktree.repo) {
                    files += diff
                }
            }
            let commits = await (try? Git.commits(at: targets[0].0.path, base: targets[0].1)) ?? []
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

    private func worktreePath(for file: FileDiff) -> String? {
        guard let session = currentSession else { return nil }
        return worktrees.first { session.owns($0) && $0.repo == (file.repo ?? session.repos.first) }?.path
    }

    private func openDiffFile() {
        guard let file = currentDiffFile, let root = worktreePath(for: file) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: root).appendingPathComponent(file.path))
    }

    /// Types a question about the hunk into the agent's pane, unsent, and switches to INSERT there to finish it.
    private func askAboutHunk() {
        guard let location = diffLocation, let session = currentSession, let layout = layouts[session.id],
              let (tabIndex, paneID) = agentPane(in: layout)
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
        case .sessions: cursor = 0
        case .history: historyCursor = 0
        case .repos: repoCursor = 0
        case .inbox, .issues, .prs: itemCursor[view] = 0
        }
    }

    /// How many rows the current view's filter leaves.
    var filterMatches: Int {
        switch view {
        case .sessions: list.ordered.count
        case .history: historyRows.count
        case .repos: worktreeRows.count
        case .inbox, .issues, .prs: itemIDs(view).count
        }
    }

    // MARK: Start work

    private func openStartWork(prompt: String) {
        startWorkError = nil
        let context = startContext
        if view == .history { view = .sessions }
        startWork = StartWorkForm(
            repos: repos, lastWorked: StartWork.lastWorked(sessions: sessions, closed: history), context: context,
            settings: settings, prompt: prompt, integration: integration
        )
    }

    /// What the cursor is on, as a hint for Start work's repo: the session, worktree, history entry, or the items
    /// `s` would start from (else the one under the cursor).
    private var startContext: StartContext? {
        func items(_ found: [(repo: Repo, label: String)]) -> StartContext? {
            guard let first = found.first else { return nil }
            var ids: [String] = []
            for item in found where !ids.contains(item.repo.slug) {
                ids.append(item.repo.slug)
            }
            return StartContext(repos: ids, label: found.count == 1 ? first.label : "\(found.count) items")
        }
        switch view {
        case .sessions:
            return currentSession.map { session in
                StartContext(
                    repos: session.repos.map(\.slug), label: session.worktreeName
                )
            }
        case .repos:
            guard worktreeRows.indices.contains(repoCursor) else { return nil }
            let row = worktreeRows[repoCursor]
            return StartContext(
                repos: [row.repo.slug], label: row.branch ?? row.repo.name
            )
        case .history:
            return selectedHistory.map { entry in
                StartContext(
                    repos: entry.session.repos.map(\.slug),
                    label: entry.session.worktreeName
                )
            }
        case .inbox:
            let ids = Set(actionIDs(.inbox))
            return items(inboxRows.filter { ids.contains($0.id) }.map { item in
                (item.repo, item.number.map { "\(item.repo.name)#\($0)" } ?? item.repo.name)
            })
        case .issues:
            let ids = Set(actionIDs(.issues))
            return items(issueRows.filter { ids.contains($0.id) }.map { ($0.repo, "\($0.repo.name)#\($0.number)") })
        case .prs:
            let ids = Set(actionIDs(.prs))
            return items(pullRows.filter { ids.contains($0.id) }.map {
                ($0.ref.repo, "\($0.ref.repo.name)#\($0.ref.number)")
            })
        }
    }

    private func handleStartWork(_ stroke: KeyStroke) {
        guard var form = startWork else { return }
        if stroke == KeyStroke("v", .command), let text = NSPasteboard.general.string(forType: .string) {
            form.paste(text)
            startWork = form
            return
        }
        switch form.handle(stroke) {
        case .handled, .ignored:
            startWork = form
        case .cancel:
            startWork = nil
        case let .start(plan):
            startWork = form
            begin(plan)
        }
    }

    private func begin(_ plan: StartWorkPlan) {
        guard !startingWork else { return }
        guard !isFixture else {
            flash = "fixture: no IO"
            startWork = nil
            return
        }
        startingWork = true
        let settings = settings
        Task {
            defer { startingWork = false }
            do {
                let changes = try await StartWork.execute(plan, settings: settings)
                for case let .layoutChanged(_, layout) in changes {
                    for pane in layout.tabs.flatMap(\.tree.panes) where pane.command != nil {
                        TerminalSurfaces.shared.autostartPanes.insert(pane.id)
                    }
                }
                commit(changes)
                startWork = nil
                view = .sessions
                if case let .sessionUpserted(session)? = changes.first(where: {
                    if case .sessionUpserted = $0 { true } else { false }
                }) {
                    select(sessionID: session.id)
                }
                // A session starts with its agent pane taking your keys.
                if let tab = currentTab, let agent = tab.tree.panes.first(where: { $0.role == .agent }) {
                    focusPane(agent.id)
                }
                enterInsert()
                flash = "started \(plan.name)"
            } catch {
                flash = "start work failed: \(error)"
                startWorkError = "start failed: \(error)"
            }
        }
    }

    // MARK: Panes and tabs

    private func updateLayout(_ edit: (inout SessionLayout) -> Void) {
        guard let id = currentSession?.id, var layout = layouts[id] else { return }
        edit(&layout)
        commit(.layoutChanged(session: id, layout))
    }

    private func updateTab(_ edit: (inout PaneTab) -> Void) {
        updateLayout { layout in
            guard layout.tabs.indices.contains(layout.activeTab) else { return }
            edit(&layout.tabs[layout.activeTab])
        }
    }

    private func split(_ axis: PaneTree.Axis) {
        guard let session = currentSession else { return }
        let directory = currentTab?.tree.panes.first?.directory ?? NSHomeDirectory()
        updateTab { $0.split(axis, with: PaneSpec(role: .shell, title: "zsh \(session.branch)", directory: directory)) }
    }

    private func closePane() {
        guard let session = currentSession, let closing = currentTab?.focused else { return }
        removePane(closing, in: session.id)
    }

    /// Takes a pane out of a session's layout (and its tab, when it was the tab's last). A session left with no
    /// terminal at all asks what to do with it.
    private func removePane(_ paneID: String, in sessionID: String) {
        guard var layout = layouts[sessionID], layout.removePane(paneID) else { return }
        commit(.layoutChanged(session: sessionID, layout))
        TerminalSurfaces.shared.close(paneID: paneID)
        if layout.tabs.isEmpty { sessionEmptied(sessionID) }
    }

    /// A pane's terminal ended (its shell exited): the pane closes, as in any terminal.
    ///
    /// Only one at a time, though. Exits arrive in a short batch first: when terminals in more than one session end
    /// together, they were lost (heed quitting or being replaced, the terminal runtime failing), not closed, and no
    /// session is touched; they come back on the next launch. And none count while heed quits.
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

    /// A batch of ended terminals: closed when they are all one session's, left alone when they span sessions.
    func panesEnded(_ batch: Set<String>) {
        guard !terminating else { return }
        let owners = batch.compactMap { pane in
            layouts.first { $0.value.tabs.contains { $0.tree.panes.contains { $0.id == pane } } }
                .map { (pane: pane, session: $0.key) }
        }
        guard Set(owners.map(\.session)).count <= 1 else {
            NSLog(
                "heed: \(owners.count) terminals in \(Set(owners.map(\.session)).count) sessions ended at once; sessions left as they were"
            )
            flash = "\(owners.count) terminals ended at once; sessions kept, they reopen on the next launch"
            return
        }
        for owner in owners {
            removePane(owner.pane, in: owner.session)
        }
    }

    /// Panes whose terminal ended in the last moment, gathered so a mass exit is seen as one.
    private var exitedPanes: Set<String> = []
    /// Set when heed starts quitting: terminals ending then are the quit, not someone typing exit.
    private(set) var terminating = false
    func beginTerminating() { terminating = true }

    /// `tab.close`, or a tab's ×: every pane in it. A tab with the agent in it asks first.
    func closeTab(_ index: Int? = nil) {
        guard let session = currentSession, var layout = layouts[session.id] else { return }
        let index = index ?? layout.activeTab
        guard layout.tabs.indices.contains(index) else { return }
        let panes = layout.tabs[index].tree.panes
        let close: @MainActor () -> Void = { [weak self] in
            guard let self, var layout = layouts[session.id], layout.tabs.indices.contains(index) else { return }
            layout.removeTab(at: index)
            commit(.layoutChanged(session: session.id, layout))
            for pane in panes {
                TerminalSurfaces.shared.close(paneID: pane.id)
            }
            if layout.tabs.isEmpty { sessionEmptied(session.id) }
        }
        guard panes.contains(where: { $0.role == .agent }) else { return close() }
        layout.activeTab = index
        ask(Confirmation(
            title: "Close the \(layout.tabs[index].title) tab?",
            lines: ["The agent in it stops; the session and its worktree stay"],
            accept: "Close"
        ) { close() })
    }

    /// Every terminal of a session has gone. Delete it and its worktree, close it (worktree kept), or keep it with a
    /// fresh shell.
    private func sessionEmptied(_ id: String) {
        if mode == .insert, currentSession?.id == id { engine.enter(.normal) }
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let (removals, kept, lines) = deletion(of: session)
        // ↩ keeps the session: this dialog follows an exit, not a choice, so the safe answer is the default one.
        // Deleting takes its own key.
        ask(Confirmation(
            title: "Every terminal in \(session.title) has closed.",
            lines: ["Keep opens a new shell in it; Close and Delete move it to History"]
                + lines.map { "Delete would \($0.prefix(1).lowercased())\($0.dropFirst())" },
            kept: kept,
            accept: "Keep",
            cancel: "Keep",
            destructive: false,
            action: { [weak self] in self?.reopenShell(in: id) },
            alternatives: [
                .init(label: "Close, keep the worktree", key: "c") { [weak self] in self?.closeSession(id) },
                .init(label: "Delete", key: "d", destructive: true) { [weak self] in
                    self?.deleteSession(id, removals: removals, kept: kept)
                },
            ],
            onCancel: { [weak self] in self?.reopenShell(in: id) }
        ))
    }

    /// Keep: the session gets a shell tab again, in its worktree.
    private func reopenShell(in id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let directory = worktrees.first { session.owns($0) }?.path
            ?? NSHomeDirectory()
        var layout = layouts[id] ?? SessionLayout(tabs: [])
        layout.tabs.append(PaneTab(title: "shell", tree: .leaf(PaneSpec(
            role: .shell, title: "zsh \(session.branch)", directory: directory
        ))))
        layout.activeTab = layout.tabs.count - 1
        commit(.layoutChanged(session: id, layout))
        flash = "kept \(session.title), with a new shell"
    }

    private func cycleTab(by delta: Int) {
        updateLayout { layout in
            let count = layout.tabs.count
            guard count > 0 else { return }
            layout.activeTab = ((layout.activeTab + delta) % count + count) % count
        }
    }

    private func newTab() {
        let directory = currentTab?.tree.panes.first?.directory ?? NSHomeDirectory()
        updateLayout { layout in
            layout.tabs.append(PaneTab(title: "shell", tree: .leaf(PaneSpec(
                role: .shell, title: "zsh", directory: directory
            ))))
            layout.activeTab = layout.tabs.count - 1
        }
    }

    func selectTab(_ index: Int) {
        updateLayout { $0.activeTab = index }
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

    /// The key for a command as you have it bound: NORMAL first, then the view bindings (`Iw` lives in Sessions').
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

    /// The Dock badge and the menu bar item, from the sessions that need you.
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

    /// A session chosen outside the window (the menu bar): Heed in front, on that session.
    func show(sessionID: String) {
        view = .sessions
        select(sessionID: sessionID)
        activateHeed()
    }

    // MARK: Mouse

    /// Clicking into a terminal means typing there: focus that pane and enter INSERT. Without this a click left
    /// NORMAL on, and the next letters ran as commands (x closes the session).
    func clickedPane(_ paneID: String) {
        guard startWork == nil, resume == nil, firstRun == nil, !filtering else { return }
        if currentTab?.focused != paneID { focusPane(paneID) }
        enterInsert()
    }

    /// Whether a click on a list may act: not while a dialog or form has the keyboard.
    private var clicksReachLists: Bool {
        startWork == nil && confirmation == nil && resume == nil && firstRun == nil && importPicker == nil
            && pathImport == nil
    }

    /// A click on a session in the sidebar or the rail selects it; a double-click also types into its agent pane.
    func clickSession(_ id: String, insert: Bool = false) {
        guard clicksReachLists else { return }
        clickedOutsideTerminal()
        select(sessionID: id)
        guard insert, let layout = layouts[id], let (tabIndex, paneID) = agentPane(in: layout) else { return }
        selectTab(tabIndex)
        clickedPane(paneID)
    }

    /// A click on a list row (Inbox, Issues, PRs, Watch, Repos, History) moves the cursor there; a double-click opens
    /// it, as ↩ does.
    func clickRow(_ list: AppView, _ index: Int, open: Bool = false) {
        guard clicksReachLists, view == list else { return }
        clickedOutsideTerminal()
        setRow(index)
        if open { openSelected() }
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
    case all = "All", assigned = "Assigned", mentioned = "Mentioned", watched = "Watched repos"

    var next: IssueFilter {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    func matches(_ issue: Issue) -> Bool {
        switch self {
        case .all: true
        case .assigned: issue.assigned
        case .mentioned: issue.mentioned
        case .watched: !issue.involvesYou
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
    case session(String)
    case pane(String)
    /// A row in a view's list, by position.
    case row(AppView, Int)
}
