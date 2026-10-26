import HeedCore
import SwiftUI

/// Every screenshot in the docs, generated from the fake world by `mise run shots`. A shot's id is its path under
/// docs/images/shots; pages reference them as `../images/shots/<id>.png`.
@MainActor
enum Shots {
    static let all: [Shot] = landing + home + gettingStarted + concepts + tasks + github + diff + keyboard + outside
        + configuration

    /// Types a sentence (spaces become <Space>).
    static func typed(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "<Space>")
    }

    static let firstRunReport = FirstRunReport(
        githubUser: "you",
        agents: [
            .init(name: "claude", path: "/Users/you/.local/bin/claude"),
        ],
        tools: ToolReport(
            shell: "/opt/homebrew/bin/fish", shellPath: ["/opt/homebrew/bin", "/usr/bin"],
            searchPath: ["/opt/homebrew/bin", "/usr/bin", "/bin"],
            tools: [
                ResolvedTool(
                    name: "git",
                    path: "/opt/homebrew/bin/git",
                    version: "git version 2.51.0",
                    source: .loginShell,
                    problem: nil
                ),
                ResolvedTool(
                    name: "gh",
                    path: "/opt/homebrew/bin/gh",
                    version: "gh version 2.96.0",
                    source: .loginShell,
                    problem: nil
                ),
            ]
        )
    )

    static let gettingStarted: [Shot] = [
        Shot(id: "getting-started/first-run", crop: .dialog, prepare: { $0.showFirstRun(report: firstRunReport) }),
        Shot(id: "getting-started/first-task-1-new", keys: "o" + typed("Fix image upload 403"), crop: .dialog),
        Shot(id: "getting-started/first-task-2-working", keys: "2j", highlight: [.panes]),
        Shot(id: "getting-started/first-task-3-asking", keys: "j", highlight: [.sidebar, .panes]),
        Shot(id: "getting-started/first-task-4-insert", keys: "ji", highlight: [.panes]),
        Shot(id: "getting-started/first-task-5-pr", keys: "2jgo"),
    ]

    static let concepts: [Shot] = [
        Shot(id: "concepts/task", keys: "2j", highlight: [.tabStrip, .panes, .inspector]),
        Shot(id: "concepts/states", size: CGSize(width: 1440, height: 640), crop: .sidebar),
        Shot(id: "concepts/mode-normal", crop: .statusBar, cropPadding: 0),
        Shot(id: "concepts/mode-insert", keys: "i", crop: .statusBar, cropPadding: 0),
        Shot(id: "concepts/mode-visual", keys: "gmv", crop: .statusBar, cropPadding: 0),
        Shot(id: "concepts/mode-command", keys: ":", crop: .statusBar, cropPadding: 0),
        Shot(id: "concepts/mode-hint", keys: "f", crop: .statusBar, cropPadding: 0),
    ]

    /// The landing page (docs/heed-landing.html), which draws its own window frames: no chrome here.
    static let landing: [Shot] = [
        Shot(id: "landing/main", chrome: false, keys: "2j"),
        Shot(id: "landing/states", chrome: false, keys: "j"),
        Shot(id: "landing/new-task", chrome: false, keys: "o" + typed("Fix image upload 403")),
        Shot(id: "landing/agents", subject: .settings(.agents), size: CGSize(width: 1100, height: 700)),
        Shot(id: "landing/keys", chrome: false, keys: "?"),
        Shot(id: "landing/prs", chrome: false, keys: "gp"),
        Shot(id: "landing/pr", chrome: false, keys: "2jgo"),
        Shot(id: "landing/resume", chrome: false, prepare: { $0.showResumeForFixture() }),
        Shot(id: "landing/diff", chrome: false, keys: "2jgd"),
        Shot(id: "landing/inbox", chrome: false, keys: "gm<Space>j<Space>"),
    ]

    /// The docs' home page.
    static let home: [Shot] = [
        Shot(id: "home/tasks", keys: "2j"),
    ]

    static let tasks: [Shot] = [
        Shot(id: "tasks/anatomy", keys: "2j", highlight: [.sidebar, .center, .inspector]),
        Shot(id: "tasks/sidebar", size: CGSize(width: 1440, height: 640), crop: .sidebar),
        Shot(id: "tasks/rail", size: CGSize(width: 1440, height: 640), keys: "zs", crop: .rail),
        Shot(id: "tasks/moving", size: CGSize(width: 1440, height: 640), keys: "2j", crop: .sidebar),
        Shot(id: "tasks/attention", size: CGSize(width: 1440, height: 640), keys: "ga", crop: .sidebar),
        Shot(id: "tasks/insert-before", keys: "2j", crop: .panes),
        Shot(id: "tasks/insert-after", keys: "2ji", crop: .panes),
        Shot(id: "tasks/split", keys: "2j<C-w>v", highlight: [.panes]),
        Shot(id: "tasks/tab-strip", keys: "2j", crop: .tabStrip, cropPadding: 6),
        Shot(id: "tasks/tab-strip-insert", keys: "2ji", crop: .tabStrip, cropPadding: 6),
        Shot(id: "tasks/zoom", keys: "2j<C-w>z", highlight: [.panes]),
        Shot(id: "tasks/inspector", keys: "2j", crop: .inspector, cropPadding: 0),
        Shot(id: "tasks/links-picker", keys: "2jgB", crop: .picker),
        Shot(id: "tasks/resume", crop: .dialog, prepare: { $0.showResumeForFixture() }),
        Shot(id: "tasks/filter-typing", keys: "/upload", crop: .statusBar, cropPadding: 0),
        Shot(id: "tasks/filter-kept", size: CGSize(width: 1440, height: 640), keys: "/upload<CR>", crop: .sidebar),
        Shot(id: "tasks/new-task", keys: "o" + typed("Fix image upload 403"), crop: .dialog),
        Shot(id: "tasks/new-task-picked", keys: "gi<Space>j<Space>", highlight: [.list, .pickedPanel]),
        Shot(id: "tasks/new-task-from-github", keys: "gis", crop: .dialog),
    ]

    static let short = CGSize(width: 1440, height: 640)

    static let github: [Shot] = [
        Shot(id: "github/offline", keys: "gm", highlight: [.syncBanner], prepare: { model in
            var state = model.github
            state.status = .offline("gh: could not resolve host api.github.com")
            model.commit(.githubSynced(state))
        }),
        Shot(id: "github/inbox", keys: "gm", highlight: [.chips]),
        Shot(id: "github/inbox-rows", size: short, keys: "gm", crop: .list),
        Shot(id: "github/issues", keys: "gi", highlight: [.issueRepos, .chips]),
        Shot(id: "github/issue-rows", size: short, keys: "gi", crop: .list),
        Shot(id: "github/prs", keys: "gp"),
        Shot(id: "github/reader-pr", keys: "gpgo"),
        Shot(id: "github/reader-issue", size: CGSize(width: 1200, height: 420), keys: "gigo", crop: .reader),
        Shot(id: "github/pr-overlay", keys: "2jgo"),
    ]

    static let diff: [Shot] = [
        Shot(id: "diff/overlay", keys: "2jgd"),
        Shot(id: "diff/split", keys: "2jgdt"),
    ]

    static let keyboard: [Shot] = [
        Shot(id: "keyboard/leader", keys: "g", crop: .leaderHints),
        Shot(id: "keyboard/view-tabs", crop: .viewTabs, cropPadding: 8),
        Shot(id: "keyboard/hints-tasks", keys: "f"),
        Shot(id: "keyboard/hints-list", size: short, keys: "gif", crop: .list),
        Shot(id: "keyboard/command-line", keys: ":vie", crop: .commandLine),
        Shot(id: "keyboard/visual", size: short, keys: "gmvj", crop: .list),
    ]

    static let configuration: [Shot] = [
        Shot(id: "configuration/problem", keys: "", crop: .statusBar, cropPadding: 0, prepare: { model in
            model.applyConfig(source: "[sessions]\nresume_on_launch = \"sometimes\"\n")
        }),
        Shot(id: "configuration/settings", subject: .settings(), size: CGSize(width: 900, height: 1180)),
    ]

    static let outside: [Shot] = [
        Shot(id: "outside/menu-bar", subject: .menuBar, size: CGSize(width: 520, height: 34)),
        Shot(id: "outside/menu", subject: .menu, size: CGSize(width: 620, height: 380)),
        Shot(id: "outside/dock", subject: .dock, size: CGSize(width: 420, height: 130), crop: .picker, cropPadding: 30),
    ]
}
