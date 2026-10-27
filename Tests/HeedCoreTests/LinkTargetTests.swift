@testable import HeedCore
import Testing

struct LinkTargetTests {
    private let main = "/Users/you/www/kibana"
    private var tasks: [WorkTask] {
        [
            WorkTask(id: "sse", title: "Investigate SSE batching"),
            WorkTask(id: "main", title: "Kibana main", pinned: true, worktree: main, branch: "main"),
            WorkTask(id: "upload", title: "Fix image upload 403", worktree: "/Users/you/www/kibana.worktrees/upload"),
            WorkTask(id: "old", title: "Upgrade EUI", status: .done, worktree: "/Users/you/www/kibana.worktrees/eui"),
        ]
    }

    @Test func aLinkStaysInTheTaskItCameFrom() {
        #expect(LinkTarget.task(from: "upload", in: tasks, mainCheckout: main) == "upload")
        // A task in the main checkout without a worktree is still its own task.
        #expect(LinkTarget.task(from: "sse", in: tasks, mainCheckout: main) == "sse")
    }

    @Test func otherwiseItGoesToKibanaMain() {
        #expect(LinkTarget.task(from: nil, in: tasks, mainCheckout: main) == "main")
        #expect(LinkTarget.task(from: "gone", in: tasks, mainCheckout: main) == "main")
        #expect(LinkTarget.task(from: "old", in: tasks, mainCheckout: main) == "main")
    }

    @Test func kibanaMainIsThePinnedTaskInTheMainCheckout() {
        let unpinned = WorkTask(id: "other", title: "Also on main", worktree: main)
        let pinnedWorktree = WorkTask(id: "pinned", title: "Pinned elsewhere", pinned: true, worktree: "/tmp/wt")
        #expect(LinkTarget.task(from: nil, in: [unpinned, pinnedWorktree] + tasks, mainCheckout: main) == "main")
        #expect(LinkTarget.task(from: nil, in: [unpinned, pinnedWorktree], mainCheckout: main) == nil)
        // pk may record no worktree for it: its directory is still the main checkout.
        let noWorktree = WorkTask(id: "bare", title: "Kibana main", pinned: true, branch: "main")
        #expect(LinkTarget.task(from: nil, in: [noWorktree], mainCheckout: main) == "bare")
    }

    @Test func noKibanaMainNoTask() {
        let done = WorkTask(id: "main", title: "Kibana main", status: .done, pinned: true, worktree: main)
        #expect(LinkTarget.task(from: nil, in: [done], mainCheckout: main) == nil)
        #expect(LinkTarget.task(from: nil, in: [], mainCheckout: main) == nil)
    }

    @Test func onlyWebLinksBecomePages() {
        #expect(LinkTarget.opensAsPage("https://github.com/elastic/kibana/pull/1"))
        #expect(LinkTarget.opensAsPage("http://kibana.localhost/app/agent_builder"))
        #expect(!LinkTarget.opensAsPage("mailto:me@example.com"))
        #expect(!LinkTarget.opensAsPage("file:///Users/you/notes.md"))
        #expect(!LinkTarget.opensAsPage("/Users/you/www/kibana/package.json"))
    }
}
