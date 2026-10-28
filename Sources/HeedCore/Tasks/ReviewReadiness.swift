import Foundation

/// When Heed asks pk to move a task to Ready for Review: its PR went from not ready (a draft, or closed) to open and
/// not a draft between two GitHub syncs. Only that change counts, never the PR's state alone, so a task moved back to
/// In Progress by hand while its PR is open stays there. pk owns the rule itself (`task.pr.ready` checks the PR again
/// and moves only In Progress); a newly linked PR is pk's to judge when it links it.
public enum ReviewReadiness {
    /// Open for review: open and not a draft.
    public static func isReady(_ pull: PullRequest) -> Bool { pull.state == .open && !pull.isDraft }

    /// The In Progress tasks whose PR became ready from `before` to `after`. `before` is the previous sync, which after
    /// a relaunch is the cached one, so a PR marked ready while Heed was closed still counts. A PR `before` does not
    /// have is the baseline, not a change.
    public static func opened(before: [PullRequest], after: [PullRequest], tasks: [WorkTask]) -> [WorkTask] {
        let seen = Dictionary(before.map { ($0.ref, isReady($0)) }, uniquingKeysWith: { first, _ in first })
        let opened = Set(after.filter { isReady($0) && seen[$0.ref] == false }.map(\.ref))
        return tasks.filter { task in
            task.status == .inProgress && task.pull.map(opened.contains) == true
        }
    }
}
