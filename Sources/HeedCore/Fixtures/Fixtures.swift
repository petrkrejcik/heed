import Foundation

/// Domains to start the UI in without any IO: one per design board. `HEED_FIXTURE=<name>` opens the app on one with
/// every adapter switched off.
public enum Fixtures {
    /// `resume` is `tasks` opening on the resume dialog, `firstrun` is `empty` opening on the first-run dialog (the
    /// app handles those names).
    public static let names = ["tasks", "empty", "resume", "pr-storm", "firstrun"]

    /// The home folder of the fixtures' world; the app points `Paths.home` here so `~/www/kibana` is the main checkout.
    public static let home = "/Users/you"

    static let kibana = Kibana.repo
    static let eui = Repo(org: "elastic", name: "eui")
    static let worktrees = "\(home)/www/kibana.worktrees"
    static let notes = "\(home)/notes/Projects"

    static func issueURL(_ number: Int) -> String { "https://github.com/elastic/kibana/issues/\(number)" }
    static func pullURL(_ number: Int) -> String { PullRef(repo: kibana, number: number).url }

    /// What the issue links of the fake world fetched: their titles and states.
    public static let issueInfo: [IssueRef: IssueInfo] = [
        IssueRef(repo: kibana, number: 299_433): IssueInfo(
            title: "Image upload returns 403 behind a proxy", closed: false,
            body: "Uploading an image in the chat fails with 403 when Kibana runs behind a reverse proxy.",
            labels: ["bug", "Team:AI Infra"], author: "reporter", updatedAt: Clock.now.addingTimeInterval(-86400)
        ),
    ]

    public static func named(_ name: String) -> Domain? {
        switch name {
        case "tasks": tasks
        case "empty": .empty
        case "pr-storm": prStorm
        default: nil
        }
    }

    /// design/screens/Main.png: the plan's task list. Pinned, In Progress, Blocked and Ready for Review are open; To
    /// Do,
    /// Done and Dropped collapsed. The rows keep the order the docs' shots count on (`2j` is the upload fix).
    public static let tasks: Domain = {
        let now = Clock.now
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let main = "\(home)/www/kibana"
        let upload = "\(worktrees)/299433-fix-image-upload-403"
        let review = "\(worktrees)/review-299044-timeline-freeze"
        let undo = "\(worktrees)/298812-chat-input-cmd-z"
        let scroll = "\(worktrees)/298760-keep-scroll"
        let list = [
            WorkTask(
                id: "t1", title: "Kibana main", status: .inProgress, pinned: true, branch: "main",
                notePath: "\(notes)/Kibana main.md", port: 5601, running: true, lastActivity: ago(40)
            ),
            WorkTask(
                id: "t2", title: "Fix image upload 403", status: .inProgress, issue: issueURL(299_433),
                pr: pullURL(299_455),
                worktree: upload, branch: "299433-fix-image-upload-403",
                notePath: "\(notes)/Fix image upload 403.md", port: 5602, running: true, epic: "Chat attachments",
                lastActivity: ago(2)
            ),
            WorkTask(
                id: "t3", title: "Review PR 299044 - Timeline freeze", status: .inProgress, kind: "review",
                pr: pullURL(299_044), worktree: review, branch: "review-299044-timeline-freeze",
                notePath: "\(notes)/Review PR 299044 - Timeline freeze.md", port: 5603, running: false,
                lastActivity: ago(57)
            ),
            WorkTask(
                id: "t4", title: "Chat input cmd+z breaks after paste", status: .blocked, issue: issueURL(298_812),
                pr: pullURL(298_830), worktree: undo, branch: "298812-chat-input-cmd-z",
                notePath: "\(notes)/Chat input cmd+z breaks after paste.md", port: 5604, running: false,
                lastActivity: ago(60 * 26)
            ),
            WorkTask(
                id: "t5", title: "Investigate SSE batching", status: .inProgress, pr: pullURL(299_480),
                notePath: "\(notes)/Investigate SSE batching.md", lastActivity: ago(1)
            ),
            WorkTask(
                id: "t6", title: "Upgrade the chat to EUI 101", status: .done, pr: pullURL(298_140),
                notePath: "\(notes)/Upgrade the chat to EUI 101.md", lastActivity: ago(60 * 50)
            ),
            WorkTask(
                id: "t7", title: "Document the chat API", status: .toDo,
                notePath: "\(notes)/Document the chat API.md", lastActivity: ago(60 * 70)
            ),
            WorkTask(
                id: "t8", title: "Keep scroll position on new messages", status: .readyForReview,
                pr: pullURL(298_901), worktree: scroll, branch: "298760-keep-scroll",
                notePath: "\(notes)/Keep scroll position on new messages.md", port: 5605, running: false,
                lastActivity: ago(60 * 5)
            ),
            WorkTask(
                id: "t9", title: "Conversation list flickers when renaming", status: .toDo, issue: issueURL(299_120),
                notePath: "\(notes)/Conversation list flickers when renaming.md", lastActivity: ago(60 * 20)
            ),
            WorkTask(
                id: "t10", title: "Try a streaming markdown renderer", status: .dropped,
                notePath: "\(notes)/Try a streaming markdown renderer.md", lastActivity: ago(60 * 30)
            ),
        ].map { task in
            var task = task
            task.record("started · claude in \(Paths.abbreviate(task.directory))", at: ago(60 * 3))
            return task
        }
        var tasks = list
        tasks[1].record("opened PR #299455", at: ago(50))
        tasks[1].record("asked: allow Bash(yarn test:jest)?", at: ago(9))
        tasks[1].record("running jest · 2m", at: ago(2))

        let layouts: [String: TaskLayout] = [
            "t1": panes("t1", [agentTab("t1", main)], [
                shellTab("t1", main),
                PaneTab(id: "t1-t2", title: "kibana", pane: PaneSpec(
                    id: "t1-kibana", role: .shell, title: "yarn start", directory: main, command: "yarn start"
                )),
            ]),
            "t2": panes("t2", [agentTab("t2", upload), agentTab("t2", upload, second: true)], [
                PaneTab(id: "t2-t3", title: "jest", pane: PaneSpec(
                    id: "t2-jest", role: .command, title: "jest", directory: upload, command: "yarn test:jest"
                )),
                shellTab("t2", upload),
                PaneTab(id: "t2-t4", title: "Agent Builder - Elastic", pane: PaneSpec(
                    id: "t2-page", role: .browser, title: "Agent Builder - Elastic", directory: upload,
                    url: "http://299433-fix-image-upload-403.localhost/app/agent_builder"
                )),
            ]),
            "t3": panes("t3", [agentTab("t3", review)], [
                PaneTab(id: "t3-t2", title: "localhost", pane: PaneSpec(
                    id: "t3-page", role: .browser, title: "", directory: review,
                    url: "http://localhost:5603/app/agent_builder"
                )),
            ]),
            "t4": TaskLayout(tabs: [agentTab("t4", undo)]),
            "t5": TaskLayout(tabs: [agentTab("t5", main)]),
            "t8": TaskLayout(tabs: [agentTab("t8", scroll)]),
        ]
        /// `turn`: minutes since its last turn ended, where the prompt cache countdown starts.
        func agent(
            _ state: AgentState, _ activity: String, reason: String? = nil, id: String, turn: Double? = nil
        ) -> AgentTab {
            AgentTab(
                state: ObservedState(state, reason: reason), activity: activity, claudeSessionID: id,
                lastTurnAt: turn.map(ago)
            )
        }
        // The cache tags: Kibana main 20m, the upload fix 42m (its working agent refreshes its own cache, the idle one
        // counts), the review 3m (amber); the others expired.
        let agents: [String: AgentTab] = [
            "t1-agent": agent(.idle, "idle 40m", id: "4d0c2a5e-1f6b-4c8e-9a37-2b5e8d1f0c64", turn: 40),
            "t2-agent": agent(.working, "running jest · 2m", id: "7f3a9c1e-52b4-4e0d-9a61-0c8d3e1f2b77", turn: 30),
            "t2-agent2": agent(.idle, "idle 18m", id: "2c81d6aa-9e17-4b3f-8d05-6a4e7b9c0d12", turn: 18),
            "t3-agent": agent(.idle, "idle 57m", id: "91be40d2-7a35-4c68-b2f9-13e5a8d07c46", turn: 57),
            "t4-agent": agent(.idle, "idle 1d", id: "e0457f3b-18c2-4d9a-a6b1-5f2d9c8e3a04", turn: 60 * 26),
            "t8-agent": agent(.done, "done 5h", id: "5a9e2f60-3c71-4b8d-9e24-81f0d6c3a7b5", turn: 60 * 5),
            "t5-agent": agent(
                .asking,
                "2 questions waiting",
                reason: "2 questions",
                id: "b36c9d71-04fa-42e8-8a3d-7e1c5b2f9d60"
            ),
        ]
        return Domain(
            tasks: tasks, layouts: layouts, agents: agents, github: github,
            pullDetails: Dictionary(([pullDetail] + otherDetails).map { ($0.ref.description, $0) }) { first, _ in
                first
            }
        )
    }()

    /// A PR storm: #299455, with its review comments and failing check, is the PR updated last, while the task that
    /// owns it is busy working.
    public static let prStorm: Domain = {
        var domain = tasks
        if let index = domain.github.pulls.firstIndex(where: { $0.ref == pullDetail.ref }) {
            var pull = domain.github.pulls.remove(at: index)
            pull.updatedAt = Clock.now
            domain.github.pulls.insert(pull, at: 0)
        }
        return domain
    }()

    /// design/screens/Diff.png.
    public static let diffCommits = [
        CommitSummary(sha: "4f2a1c0", subject: "Send the upload through the Kibana base path"),
        CommitSummary(sha: "a91e3d0", subject: "Fix lint in upload_image.ts"),
        CommitSummary(sha: "0be7d20", subject: "Add a test for uploads behind a proxy"),
    ]

    /// Where the fixture branch left main.
    public static let diffMergeBase = "7c1e9b2"

    /// The upload fix's changes: staged ones in `upload_image.ts` and `tsconfig.json`, the rest not staged.
    public static let diff: [FileDiff] = DiffParser.parse(
        diffText, repo: kibana, staged: [
            "x-pack/platform/plugins/shared/onechat/public/upload_image.ts",
            "x-pack/platform/plugins/shared/onechat/tsconfig.json",
        ]
    )

    /// A file's two sides, as `Git.contents` reads them in the real world.
    public static func contents(of path: String) -> FileContents {
        let sides = diffContents[path]
        return FileContents(
            path: path, old: sides?.old.map { .text($0) } ?? .missing, new: sides?.new.map { .text($0) } ?? .missing
        )
    }

    /// design/screens/Reader.png.
    static let pullDetail: PullDetail = {
        var detail = PullDetail(
            ref: PullRef(repo: kibana, number: 299_455), title: "[Agent Builder] Fix image upload 403 behind a proxy",
            body: "Sends chat image uploads through the Kibana base path with the xsrf header, so they work behind a reverse proxy.\nCloses #299433.",
            author: "you", baseBranch: "main", headBranch: "299433-fix-image-upload-403", additions: 82, deletions: 4,
            commitCount: 3, headSHA: "a91e3d0",
            reviews: [PullDetail.Review(author: "reviewer", state: "CHANGES_REQUESTED")],
            threads: [
                ReviewThread(
                    id: "T1", isResolved: false, path: "x-pack/platform/plugins/shared/onechat/public/upload_image.ts",
                    line: 24, author: "reviewer",
                    body: "`credentials: 'same-origin'` is the default for fetch. Do we need it here?",
                    diff: [
                        "   // the proxy strips cookies on cross-origin requests",
                        "-  const response = await fetch(url, { method: 'POST', body: file });",
                        "+  const response = await fetch(url, { method: 'POST', body: file, headers, credentials: 'same-origin' });",
                    ],
                    replies: 0, url: nil
                ),
                ReviewThread(
                    id: "T2", isResolved: false,
                    path: "x-pack/platform/plugins/shared/onechat/public/upload_image.test.ts", line: 2,
                    author: "reviewer", body: "Please cover a 403 from the proxy too.", diff: [], replies: 0, url: nil
                ),
            ],
            failingChecks: [PullDetail.FailingCheck(
                name: "lint",
                summary: "x-pack/platform/plugins/shared/onechat/README.md:41 line too long",
                url: nil
            )],
            checks: CheckSummary(passed: 3, failed: 1, pending: 1, failedNames: ["lint"]),
            closes: [PullRef(repo: kibana, number: 299_433)], fetchedAt: Clock.now
        )
        detail.state = "OPEN"
        detail.isDraft = false
        detail.mergeable = "MERGEABLE"
        detail.mergeState = "BLOCKED"
        detail.reviewDecision = "CHANGES_REQUESTED"
        detail.requiredChecks = ["build", "lint"]
        detail.references = [
            PullDetail.Reference(
                ref: PullRef(repo: kibana, number: 299_470), title: "[Agent Builder] Attachment size limits",
                author: "teammate", state: "OPEN", createdAt: Clock.now.addingTimeInterval(-50 * 60)
            ),
        ]
        return detail
    }()

    /// The other PRs' details: the one under review is green, an older one of yours conflicts, the blocked fix is a
    /// draft, the SSE spike was closed.
    static let otherDetails: [PullDetail] = {
        func detail(
            _ number: Int, _ title: String, _ branch: String, author: String, mergeable: String, state: String,
            checks: CheckSummary, review: String?, prState: String = "OPEN", draft: Bool = false
        ) -> PullDetail {
            var detail = PullDetail(
                ref: PullRef(repo: kibana, number: number), title: title, body: "", author: author,
                baseBranch: "main", headBranch: branch, additions: 20, deletions: 3, commitCount: 1,
                headSHA: "b\(number)",
                reviews: review.map { [PullDetail.Review(author: "reviewer", state: $0)] } ?? [], threads: [],
                failingChecks: [], checks: checks, closes: [], fetchedAt: Clock.now
            )
            detail.state = prState
            detail.isDraft = draft
            detail.mergeable = mergeable
            detail.mergeState = state
            detail.reviewDecision = review
            detail.requiredChecks = ["build"]
            return detail
        }
        return [
            detail(
                299_044, "[Agent Builder] Timeline freezes on long conversations", "timeline-freeze",
                author: "teammate", mergeable: "MERGEABLE", state: "CLEAN", checks: CheckSummary(passed: 4),
                review: nil
            ),
            detail(
                298_901, "[Agent Builder] Keep scroll position on new messages", "298760-keep-scroll",
                author: "you", mergeable: "CONFLICTING", state: "DIRTY", checks: CheckSummary(passed: 3),
                review: "APPROVED"
            ),
            detail(
                298_830, "[Agent Builder] Keep the undo stack after a paste", "298812-chat-input-cmd-z",
                author: "you", mergeable: "MERGEABLE", state: "CLEAN", checks: CheckSummary(passed: 4),
                review: nil, draft: true
            ),
            detail(
                299_480, "[Agent Builder] Spike: batch SSE events", "sse-batching-spike",
                author: "you", mergeable: "MERGEABLE", state: "CLEAN", checks: CheckSummary(passed: 4),
                review: nil, prState: "CLOSED"
            ),
        ]
    }()

    /// design/screens/Inbox.png and PRs.png.
    static let github: GitHubState = {
        let now = Clock.now
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func pull(
            _ number: Int, _ title: String, _ branch: String, _ checks: CheckSummary, _ review: ReviewDecision?,
            threads: Int = 0, repo: Repo = kibana
        ) -> PullRequest {
            PullRequest(
                ref: PullRef(repo: repo, number: number), title: title, url: PullRef(repo: repo, number: number).url,
                state: .open, isDraft: false, headBranch: branch, review: review, checks: checks,
                unresolvedThreads: threads, updatedAt: ago(Double(number % 60))
            )
        }
        func item(
            _ id: String, _ kind: InboxItem.Kind, _ number: Int?, _ title: String, _ reason: String, _ minutes: Double,
            repo: Repo = kibana
        ) -> InboxItem {
            InboxItem(
                id: id, kind: kind, repo: repo, number: number, title: title, reason: reason, unread: true,
                updatedAt: ago(minutes), url: nil
            )
        }
        let inbox = [
            item("n1", .pr, 299_044, "[Agent Builder] Timeline freezes on long conversations", "review_requested", 4),
            item("n2", .ci, nil, "lint failed on #299455", "ci_activity", 9),
            item("n3", .pr, 299_455, "2 new review comments", "comment", 12),
            item("n4", .issue, 299_433, "Image upload returns 403 behind a proxy", "assign", 60),
            item("n5", .issue, 299_120, "Conversation list flickers when renaming", "mention", 120),
            item("n6", .pr, 8412, "EuiMarkdownEditor: paste keeps the undo stack", "review_requested", 180, repo: eui),
            item("n7", .issue, 298_812, "Chat input cmd+z breaks after paste", "assign", 300),
        ]
        func issue(
            _ number: Int, _ title: String, _ body: String, _ labels: [String], _ minutes: Double,
            assigned: Bool = false, mentioned: Bool = false
        ) -> Issue {
            Issue(
                repo: kibana, number: number, title: title, url: "", body: body, labels: labels, author: "reporter",
                updatedAt: ago(minutes), assigned: assigned, mentioned: mentioned
            )
        }
        let issues = [
            issue(
                299_433, "Image upload returns 403 behind a proxy",
                "Uploading an image in the chat fails with 403 when Kibana runs behind a reverse proxy.",
                ["bug", "Team:AI Infra"], 60, assigned: true
            ),
            issue(
                299_120, "Conversation list flickers when renaming", "Renaming a conversation re-renders the list.",
                ["bug"], 120, mentioned: true
            ),
            issue(
                298_812, "Chat input cmd+z breaks after paste", "After pasting, cmd+z clears the whole input.",
                ["bug"], 300, assigned: true
            ),
        ]
        let pulls = [
            pull(
                299_455, "[Agent Builder] Fix image upload 403 behind a proxy", "299433-fix-image-upload-403",
                CheckSummary(passed: 3, failed: 1, pending: 1, failedNames: ["lint"]), .changesRequested, threads: 2
            ),
            pull(
                299_044,
                "[Agent Builder] Timeline freezes on long conversations",
                "timeline-freeze",
                CheckSummary(passed: 4),
                nil
            ),
            pull(
                298_901,
                "[Agent Builder] Keep scroll position on new messages",
                "298760-keep-scroll",
                CheckSummary(passed: 3),
                .approved
            ),
            {
                var merged = pull(
                    298_140, "[Agent Builder] Upgrade the chat to EUI 101", "eui-101", CheckSummary(passed: 4),
                    .approved
                )
                merged.state = .merged
                return merged
            }(),
        ]
        return GitHubState(viewer: "you", inbox: inbox, issues: issues, pulls: pulls, syncedAt: ago(0.3), status: .ok)
    }()

    /// An agent tab (`<task>-agent`, or `<task>-agent2` when `second`).
    private static func agentTab(_ task: String, _ directory: String, second: Bool = false) -> PaneTab {
        let id = second ? "\(task)-agent2" : "\(task)-agent"
        let agent = PaneSpec(id: id, role: .agent, title: "claude", directory: directory, command: "claude")
        return PaneTab(id: second ? "\(task)-t1b" : "\(task)-t1", title: "agent", pane: agent)
    }

    private static func shellTab(_ task: String, _ directory: String) -> PaneTab {
        PaneTab(
            id: "\(task)-t1s", title: "shell",
            pane: PaneSpec(id: "\(task)-shell", role: .shell, title: "zsh", directory: directory)
        )
    }

    /// The agents in a pane on the left, the rest in one on the right; the agent's pane has the keys.
    private static func panes(_ task: String, _ left: [PaneTab], _ right: [PaneTab]) -> TaskLayout {
        TaskLayout(
            root: .split(
                .horizontal, .leaf(PaneGroup(id: "\(task)-p1", tabs: left)),
                .leaf(PaneGroup(id: "\(task)-p2", tabs: right)), ratio: 0.5
            ),
            focusedGroup: "\(task)-p1"
        )
    }
}
