import Foundation
@testable import HeedCore
import Testing

private func file(_ path: String, staged: Bool = false) -> FileDiff {
    FileDiff(repo: nil, path: path, oldPath: nil, status: .modified, hunks: [], binary: false, staged: staged)
}

private func rowNames(_ rows: [DiffTree.Row]) -> [String] {
    rows.map { row in
        let indent = String(repeating: "  ", count: row.depth)
        switch row.kind {
        case let .folder(name, open): return indent + name + (open ? "/" : "/…")
        case let .file(file): return indent + (file.path as NSString).lastPathComponent
        }
    }
}

struct DiffTreeTests {
    private let files = [
        "x-pack/plugins/chat/public/upload.ts", "x-pack/plugins/chat/public/components/button.scss",
        "x-pack/plugins/chat/server/routes/attachments.ts", "x-pack/plugins/chat/README.md", "package.json",
        "x-pack/plugins/chat/public/upload.test.ts",
    ].map { file($0) }

    @Test func foldersComeFirstAndSingleFolderChainsShareARow() {
        let tree = DiffTree(files)
        #expect(rowNames(tree.rows(collapsed: [])) == [
            "x-pack/plugins/chat/",
            "  public/",
            "    components/",
            "      button.scss",
            "    upload.test.ts",
            "    upload.ts",
            "  server/routes/",
            "    attachments.ts",
            "  README.md",
            "package.json",
        ])
        // ]f walks the files in the order the tree shows them.
        #expect(tree.files.map(\.path) == [
            "x-pack/plugins/chat/public/components/button.scss", "x-pack/plugins/chat/public/upload.test.ts",
            "x-pack/plugins/chat/public/upload.ts", "x-pack/plugins/chat/server/routes/attachments.ts",
            "x-pack/plugins/chat/README.md", "package.json",
        ])
    }

    @Test func aCollapsedFolderHidesWhatIsInIt() {
        let tree = DiffTree(files)
        let rows = tree.rows(collapsed: ["x-pack/plugins/chat/public"])
        #expect(rowNames(rows) == [
            "x-pack/plugins/chat/", "  public/…", "  server/routes/", "    attachments.ts", "  README.md",
            "package.json",
        ])
        #expect(rows[1].id == "x-pack/plugins/chat/public")
        #expect(rows.last?.id == "file:package.json")
    }

    @Test func aFilesFoldersAreItsAncestors() {
        let tree = DiffTree(files)
        #expect(DiffTree.folders(containing: "x-pack/plugins/chat/public/components/button.scss", in: tree) == [
            "x-pack/plugins/chat", "x-pack/plugins/chat/public", "x-pack/plugins/chat/public/components",
        ])
        #expect(DiffTree.folders(containing: "package.json", in: tree).isEmpty)
    }
}

struct DiffReviewTests {
    private func snapshot(_ paths: [String], scope: DiffScope = .uncommitted) -> DiffSnapshot {
        DiffSnapshot(
            scope: scope, files: paths.map { file($0) },
            commits: [CommitSummary(sha: "bbb", subject: "two"), CommitSummary(sha: "aaa", subject: "one")],
            mergeBase: "m"
        )
    }

    @Test func aNewTabShowsUncommittedOnItsFirstFile() {
        var review = DiffReview()
        #expect(review.scope == .uncommitted)
        review.apply(snapshot(["b.ts", "src/a.ts"]))
        #expect(review.selected == "src/a.ts")
        #expect(review.location?.path == "src/a.ts")
    }

    @Test func aRefreshKeepsTheFileYouAreOn() {
        var review = DiffReview()
        review.apply(snapshot(["a.ts", "b.ts", "c.ts"]))
        review.select("b.ts")
        review.cursor = DiffCursor(path: "b.ts", line: 40, hunk: 2, hunks: 3)
        review.apply(snapshot(["a.ts", "b.ts", "d.ts"]))
        #expect(review.selected == "b.ts")
        #expect(review.location?.line == 40)
        // Gone from the diff (committed, reverted): the first file.
        review.apply(snapshot(["a.ts", "d.ts"]))
        #expect(review.selected == "a.ts")
        #expect(review.cursor == nil)
    }

    @Test func filesStopAtEitherEnd() {
        var review = DiffReview()
        review.apply(snapshot(["a.ts", "b.ts"]))
        #expect(review.moveFile(by: 1) && review.selected == "b.ts")
        #expect(!review.moveFile(by: 1) && review.selected == "b.ts")
        #expect(review.moveFile(by: -1) && review.selected == "a.ts")
        let moved = review.moveFile(by: -1)
        #expect(!moved)
    }

    @Test func selectingAFileOpensItsFolders() {
        var review = DiffReview()
        review.apply(snapshot(["src/a/x.ts", "src/b/y.ts"]))
        review.collapsed = ["src", "src/b"]
        review.select("src/b/y.ts")
        #expect(review.collapsed.isEmpty)
    }

    @Test func commitsCycleNewestFirstThenBack() {
        var review = DiffReview()
        review.apply(snapshot(["a.ts"]))
        #expect(review.cycleCommit() && review.scope == .commit("bbb"))
        #expect(review.cycleCommit() && review.scope == .commit("aaa"))
        #expect(review.cycleCommit() && review.scope == .uncommitted)
        #expect(review.loadedAt == nil)
        review.apply(DiffSnapshot(scope: .staged, files: [], commits: [], mergeBase: "m"))
        let cycled = review.cycleCommit()
        #expect(!cycled)
    }

    @Test func theLocationIsTheReportedLineElseTheFirstHunk() {
        var review = DiffReview()
        var changed = file("a.ts")
        changed.hunks = [Hunk(header: "@@ -10,3 +12,4 @@", oldStart: 10, newStart: 12, lines: [])]
        review.apply(DiffSnapshot(scope: .uncommitted, files: [changed], commits: [], mergeBase: "m"))
        #expect(review.location?.line == 12)
        review.cursor = DiffCursor(path: "a.ts", line: 3, side: .old)
        #expect(review.location?.line == 3)
        // A cursor from the file shown before does not count.
        review.cursor = DiffCursor(path: "b.ts", line: 99)
        #expect(review.location?.line == 12)
    }
}

struct DiffKeyTests {
    private func engine() -> ModeEngine {
        let built = Keymaps.build()
        #expect(built.problems.isEmpty)
        return ModeEngine(keymaps: built.keymaps, scoped: built.scoped)
    }

    private func run(_ engine: inout ModeEngine, _ notation: String) -> [String] {
        // swiftlint:disable:next force_try
        try! KeyNotation.parse(notation).compactMap { stroke in
            if case let .run(command) = engine.handle(stroke) { return command.name }
            return nil
        }
    }

    @Test func gdOpensTheDiffTab() {
        var engine = engine()
        #expect(run(&engine, "gd") == ["tab.diff"])
        #expect(CommandAliases.resolve("diff").name == "tab.diff")
    }

    @Test func aFocusedDiffTabHasItsOwnKeys() {
        var engine = engine()
        engine.scope = "diff"
        #expect(run(&engine, "n") == ["diff.hunk.next"])
        #expect(run(&engine, "N") == ["diff.hunk.prev"])
        #expect(run(&engine, "]f") == ["diff.file.next"])
        #expect(run(&engine, "[f") == ["diff.file.prev"])
        #expect(run(&engine, "j") == ["diff.file.next"])
        #expect(run(&engine, "k") == ["diff.file.prev"])
        #expect(run(&engine, "<Tab>") == ["diff.scope.next"])
        #expect(run(&engine, "<S-Tab>") == ["diff.scope.prev"])
        #expect(run(&engine, "c") == ["diff.commit"])
        #expect(run(&engine, "t") == ["diff.split"])
        #expect(run(&engine, "a") == ["diff.ask"])
        #expect(run(&engine, "y") == ["diff.copy"])
        #expect(run(&engine, "e") == ["diff.edit"])
        #expect(run(&engine, "r") == ["diff.refresh"])
        #expect(run(&engine, "<C-d>") == ["diff.page.down"])
        // NORMAL's own keys still work around it.
        #expect(run(&engine, "l") == ["pane.right"])
        #expect(run(&engine, "gt") == ["tab.next"])
    }

    @Test func elsewhereTheyAreNormalsKeys() {
        var engine = engine()
        engine.scope = "tasks"
        #expect(run(&engine, "j") == ["row.next"])
        #expect(run(&engine, "r") == ["tasks.refresh"])
        #expect(run(&engine, "n").isEmpty)
    }
}

struct DiffLayoutTests {
    private func agentAndWork() -> TaskLayout {
        let agent = PaneTab(title: "agent", pane: PaneSpec(id: "agent", role: .agent, title: "claude", directory: "/w"))
        let shell = PaneTab(title: "zsh", pane: PaneSpec(id: "shell", role: .shell, title: "zsh", directory: "/w"))
        return TaskLayout(
            root: .split(
                .horizontal, .leaf(PaneGroup(id: "left", tabs: [agent])), .leaf(PaneGroup(id: "right", tabs: [shell])),
                ratio: 0.5
            ),
            focusedGroup: "left"
        )
    }

    @Test func theDiffTabOpensInTheWorkPaneOnce() {
        var layout = agentAndWork()
        let diff = layout.showDiff(directory: "/w")
        #expect(diff.role == .diff && !diff.role.isTerminal)
        #expect(layout.group(ofPane: diff.id)?.id == "right")
        #expect(layout.focusedPane?.id == diff.id)
        layout.focus(pane: "agent")
        let again = layout.showDiff(directory: "/w")
        #expect(again.id == diff.id)
        #expect(layout.panes.count { $0.role == .diff } == 1)
        #expect(layout.focusedPane?.id == diff.id)
    }

    @Test func theDiffTabIsSavedWithTheLayout() throws {
        var layout = agentAndWork()
        layout.showDiff(directory: "/w")
        let decoded = try JSONDecoder().decode(TaskLayout.self, from: JSONEncoder().encode(layout))
        #expect(decoded == layout)
        #expect(decoded.diffPane?.title == "diff")
        let json = try #require(String(data: JSONEncoder().encode(decoded.diffPane), encoding: .utf8))
        #expect(json.contains(#""role":"diff""#))
    }

    @Test func cachesFromBeforeDiffTabsStillLoad() throws {
        let json = #"{"id":"p1","role":"shell","title":"zsh","directory":"/w"}"#
        #expect(try JSONDecoder().decode(PaneSpec.self, from: Data(json.utf8)).role == .shell)
        let layout = try JSONDecoder().decode(TaskLayout.self, from: JSONEncoder().encode(agentAndWork()))
        #expect(layout.diffPane == nil)
    }
}
