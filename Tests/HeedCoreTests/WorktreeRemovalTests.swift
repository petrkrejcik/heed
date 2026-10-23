import Foundation
@testable import HeedCore
import Testing

struct WorktreeRemovalTests {
    private let repo = Repo(org: "o", name: "r")

    private func worktree(_ name: String, status: WorktreeStatus? = WorktreeStatus(upstream: "origin/x")) -> Worktree {
        Worktree(repo: repo, path: "/wt/\(name)", branch: name, head: "", isMain: false, status: status)
    }

    @Test func unsavedWorkIsNeverRemoved() {
        #expect(WorktreeRemoval
            .unsafe(worktree("a", status: WorktreeStatus(ahead: 2, upstream: "origin/a"))) == "2 unpushed commits")
        #expect(WorktreeRemoval.unsafe(worktree("b", status: nil)) == "status unknown")
        let dirty = worktree("d", status: WorktreeStatus(changedFiles: 1, upstream: "origin/x"))
        #expect(WorktreeRemoval.unsafe(dirty) == "uncommitted changes")
        #expect(WorktreeRemoval.unsafe(worktree("e", status: WorktreeStatus())) == "never pushed")
        #expect(WorktreeRemoval.unsafe(worktree("c")) == nil)
    }
}
