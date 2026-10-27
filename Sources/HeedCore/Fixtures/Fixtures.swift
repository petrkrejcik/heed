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

    /// design/screens/Main.png: the plan's task list. Six tasks show; the Done and To Do ones do not.
    public static let tasks: Domain = {
        let now = Clock.now
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let main = "\(home)/www/kibana"
        let upload = "\(worktrees)/299433-fix-image-upload-403"
        let review = "\(worktrees)/review-299044-timeline-freeze"
        let undo = "\(worktrees)/298812-chat-input-cmd-z"
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
                lastActivity: ago(95)
            ),
            WorkTask(
                id: "t4", title: "Chat input cmd+z breaks after paste", status: .blocked, issue: issueURL(298_812),
                worktree: undo, branch: "298812-chat-input-cmd-z",
                notePath: "\(notes)/Chat input cmd+z breaks after paste.md", port: 5604, running: false,
                lastActivity: ago(60 * 26)
            ),
            WorkTask(
                id: "t5", title: "Investigate SSE batching", status: .inProgress,
                notePath: "\(notes)/Investigate SSE batching.md", lastActivity: ago(6)
            ),
            WorkTask(
                id: "t6", title: "Upgrade the chat to EUI 101", status: .done, pr: pullURL(298_140),
                notePath: "\(notes)/Upgrade the chat to EUI 101.md", lastActivity: ago(60 * 50)
            ),
            WorkTask(
                id: "t7", title: "Document the chat API", status: .toDo,
                notePath: "\(notes)/Document the chat API.md", lastActivity: ago(60 * 70)
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
            "t1": TaskLayout(tabs: [
                agentTab("t1", main, split: true),
                PaneTab(id: "t1-t2", title: "kibana", tree: .leaf(PaneSpec(
                    id: "t1-kibana", role: .shell, title: "yarn start", directory: main, command: "yarn start"
                ))),
            ]),
            "t2": TaskLayout(tabs: [
                agentTab("t2", upload, split: true),
                agentTab("t2", upload, second: true),
                PaneTab(id: "t2-t3", title: "jest", tree: .leaf(PaneSpec(
                    id: "t2-jest", role: .command, title: "jest", directory: upload, command: "yarn test:jest"
                ))),
                PaneTab(id: "t2-t4", title: "Agent Builder - Elastic", tree: .leaf(PaneSpec(
                    id: "t2-page", role: .browser, title: "Agent Builder - Elastic", directory: upload,
                    url: "http://299433-fix-image-upload-403.localhost/app/agent_builder"
                ))),
            ]),
            "t3": TaskLayout(tabs: [
                agentTab("t3", review),
                PaneTab(id: "t3-t2", title: "localhost", tree: .leaf(PaneSpec(
                    id: "t3-page", role: .browser, title: "", directory: review,
                    url: "http://localhost:5603/app/agent_builder"
                ))),
            ]),
            "t4": TaskLayout(tabs: [agentTab("t4", undo)]),
            "t5": TaskLayout(tabs: [agentTab("t5", main)]),
        ]
        func agent(_ state: AgentState, _ activity: String, reason: String? = nil, id: String) -> AgentTab {
            AgentTab(state: ObservedState(state, reason: reason), activity: activity, claudeSessionID: id)
        }
        let agents: [String: AgentTab] = [
            "t1-agent": agent(.idle, "idle 40m", id: "4d0c2a5e-1f6b-4c8e-9a37-2b5e8d1f0c64"),
            "t2-agent": agent(.working, "running jest · 2m", id: "7f3a9c1e-52b4-4e0d-9a61-0c8d3e1f2b77"),
            "t2-agent2": agent(.idle, "idle 18m", id: "2c81d6aa-9e17-4b3f-8d05-6a4e7b9c0d12"),
            "t3-agent": agent(.idle, "idle 1h", id: "91be40d2-7a35-4c68-b2f9-13e5a8d07c46"),
            "t4-agent": agent(.idle, "idle 1d", id: "e0457f3b-18c2-4d9a-a6b1-5f2d9c8e3a04"),
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

    public static let diff: [FileDiff] = {
        let text = """
        diff --git a/x-pack/platform/plugins/shared/onechat/public/upload_image.ts b/x-pack/platform/plugins/shared/onechat/public/upload_image.ts
        --- a/x-pack/platform/plugins/shared/onechat/public/upload_image.ts
        +++ b/x-pack/platform/plugins/shared/onechat/public/upload_image.ts
        @@ -18,9 +18,11 @@ export const uploadImage = async (
           http: HttpSetup,
           file: File
         ) => {
        -  const url = '/api/chat/attachments';
        +  const url = http.basePath.prepend('/api/chat/attachments');
        +  const headers = { 'kbn-xsrf': 'true' };
           // the proxy strips cookies on cross-origin requests
        -  const response = await fetch(url, { method: 'POST', body: file });
        +  const response = await fetch(url, { method: 'POST', body: file, headers, credentials: 'same-origin' });
           if (!response.ok) {
        +    throw new UploadError(response.status);
           }
        @@ -61,6 +63,8 @@ export const uploadImage = async (
         export class UploadError extends Error {
        +  constructor(public readonly status: number) {
        +    super(`upload failed: ${status}`);
         }
        diff --git a/x-pack/platform/plugins/shared/onechat/public/upload_image.test.ts b/x-pack/platform/plugins/shared/onechat/public/upload_image.test.ts
        new file mode 100644
        --- /dev/null
        +++ b/x-pack/platform/plugins/shared/onechat/public/upload_image.test.ts
        @@ -0,0 +1,3 @@
        +describe('uploadImage', () => {
        +  it('prepends the base path', () => {});
        +});
        diff --git a/x-pack/platform/plugins/shared/onechat/README.md b/x-pack/platform/plugins/shared/onechat/README.md
        --- a/x-pack/platform/plugins/shared/onechat/README.md
        +++ b/x-pack/platform/plugins/shared/onechat/README.md
        @@ -40,2 +40,3 @@
         Attachments go through the Kibana base path.
        -A very long line that the linter rejects because it goes on and on.
        +A shorter line.
        +Another line.

        """
        return DiffParser.parse(
            text, repo: kibana, staged: ["x-pack/platform/plugins/shared/onechat/public/upload_image.ts"]
        )
    }()

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

    /// The other PRs' details: the one under review is green, an older one of yours conflicts.
    static let otherDetails: [PullDetail] = {
        func detail(
            _ number: Int, _ title: String, _ branch: String, author: String, mergeable: String, state: String,
            checks: CheckSummary, review: String?
        ) -> PullDetail {
            var detail = PullDetail(
                ref: PullRef(repo: kibana, number: number), title: title, body: "", author: author,
                baseBranch: "main", headBranch: branch, additions: 20, deletions: 3, commitCount: 1,
                headSHA: "b\(number)",
                reviews: review.map { [PullDetail.Review(author: "reviewer", state: $0)] } ?? [], threads: [],
                failingChecks: [], checks: checks, closes: [], fetchedAt: Clock.now
            )
            detail.state = "OPEN"
            detail.isDraft = false
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

    /// An agent tab (`<task>-agent`, or `<task>-agent2` when `second`), with a shell split beside it when `split`.
    private static func agentTab(_ task: String, _ directory: String, split: Bool = false, second: Bool = false)
        -> PaneTab
    {
        let id = second ? "\(task)-agent2" : "\(task)-agent"
        let agent = PaneSpec(id: id, role: .agent, title: "claude", directory: directory, command: "claude")
        var tab = PaneTab(id: second ? "\(task)-t1b" : "\(task)-t1", title: "agent", tree: .leaf(agent))
        if split {
            tab.split(.horizontal, with: PaneSpec(
                id: "\(task)-shell", role: .shell, title: "zsh", directory: directory
            ))
            tab.focused = agent.id
        }
        return tab
    }
}
