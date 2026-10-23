import Foundation

/// A worktree removed by hand (`dd` in Repos, or deleting the session on it), decided before anything is removed.
public struct WorktreeRemoval: Equatable, Sendable {
    public let worktree: Worktree
    /// Sessions on this worktree; they move to history.
    public let sessions: [String]
    public let deleteBranch: Bool

    public init(worktree: Worktree, sessions: [String], deleteBranch: Bool) {
        self.worktree = worktree
        self.sessions = sessions
        self.deleteBranch = deleteBranch
    }

    /// Why a worktree must not be removed: dirty, unpushed, or status unknown. Nil when it is safe.
    public static func unsafe(_ worktree: Worktree) -> String? {
        guard let status = worktree.status else { return "status unknown" }
        if status.isDirty { return "uncommitted changes" }
        if status
            .hasUnpushedWork { return status.upstream == nil ? "never pushed" : "\(status.ahead) unpushed commits" }
        return nil
    }

    /// Removes the worktrees (git refuses dirty ones by itself too) and their branches, and returns the domain
    /// changes: worktree lists refreshed, affected sessions closed into history.
    public static func execute(
        _ removals: [WorktreeRemoval],
        domain: Domain,
        now: Date = Date()
    ) async -> (changes: [DomainChange], failures: [String]) {
        var failures: [String] = []
        var touchedRepos: [Repo] = []
        for removal in removals {
            guard let record = domain.repo(removal.worktree.repo.slug) else { continue }
            do {
                _ = try await ProcessRunner.output(
                    "git",
                    ["-C", record.path, "worktree", "remove", removal.worktree.path]
                )
                if removal.deleteBranch, let branch = removal.worktree.branch {
                    // Everything on it is pushed (checked by `unsafe`), so -D only drops the local name.
                    _ = try? await ProcessRunner.output("git", ["-C", record.path, "branch", "-D", branch])
                }
                touchedRepos.append(record.repo)
            } catch {
                failures.append("\(removal.worktree.path): \(error)")
            }
        }
        var changes: [DomainChange] = []
        for repo in Set(touchedRepos) {
            if let record = domain.repo(repo.slug), let listed = try? await Git.worktrees(of: record) {
                changes.append(.worktreesListed(repo: repo, listed))
            }
        }
        let removedIDs = Set(removals.filter { touchedRepos.contains($0.worktree.repo) }.flatMap(\.sessions))
        for id in removedIDs {
            guard var session = domain.session(id) else { continue }
            session.record("worktree removed", at: now)
            changes.append(.sessionClosed(HistoryEntry(session: session, closedAt: now, outcome: .cleanedUp)))
        }
        return (changes, failures)
    }
}
