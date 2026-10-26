import Foundation

/// Where a PR stands, read from GitHub only: its detail and the green verdict when heed has fetched it, else the
/// sync's summary. Cases are ordered most urgent first.
public enum PullStatus: Hashable, Sendable {
    /// Conflicts with the base, or behind it when the repo requires up to date: what.
    case conflicted(String)
    case failing(Int)
    /// Unresolved review threads, or changes requested.
    case changes(Int)
    case pending
    case draft
    /// Every rule of the green verdict holds.
    case green
    /// Checks pass by the sync's summary; not yet confirmed by the detail.
    case passing
    case closed(merged: Bool)

    /// Lower is more urgent: a session shows its most urgent PR.
    public var urgency: Int {
        switch self {
        case .conflicted, .failing: 0
        case .changes: 1
        case .pending, .draft: 2
        case .green: 3
        case .passing: 4
        case .closed: 5
        }
    }

    /// `pull` is the PR's summary from the sync (nil until it arrives).
    public static func of(pull: PullRequest?, detail: PullDetail? = nil) -> PullStatus {
        if pull?.state == .merged || detail?.state == "MERGED" { return .closed(merged: true) }
        if pull?.state == .closed || detail?.state == "CLOSED" { return .closed(merged: false) }
        if let detail {
            guard let blocker = GreenVerdict.of(detail).blocker else { return .green }
            switch (blocker.name, blocker.state) {
            case ("Ready for review", _): return .draft
            case ("No conflicts", .fail), ("Up to date", .fail): return .conflicted(blocker.detail)
            case ("Checks pass", .fail):
                let required = detail.requiredChecks ?? []
                return .failing(max(detail.failingChecks.count { required.isEmpty || required.contains($0.name) }, 1))
            case ("Threads resolved", _), ("No changes requested", _):
                return .changes(max(detail.threads.count { !$0.isResolved }, 1))
            default: return .pending
            }
        }
        guard let pull else { return .pending }
        if pull.checks.failed > 0 { return .failing(pull.checks.failed) }
        if pull.unresolvedThreads > 0 || pull.review == .changesRequested { return .changes(max(
            pull.unresolvedThreads,
            1
        )) }
        if pull.checks.pending > 0 { return .pending }
        return .passing
    }
}

/// Whether a PR is green, rule by rule. Green means GitHub has nothing left to object to on the code: no conflicts, up
/// to date when required, the required checks (every check when none are required) passed, no unresolved threads, no
/// changes requested.
public struct GreenVerdict: Hashable, Sendable {
    public struct Rule: Hashable, Sendable, Identifiable {
        public enum State: Hashable, Sendable {
            case pass, fail, wait
        }

        public var id: String { name }
        public let name: String
        public let state: State
        /// What it found: `lint failed`, `behind main`, `2 threads open`.
        public let detail: String
    }

    public let rules: [Rule]

    public var isGreen: Bool { rules.allSatisfy { $0.state == .pass } }

    /// The first rule holding the PR back, failures before waits.
    public var blocker: Rule? { rules.first { $0.state == .fail } ?? rules.first { $0.state == .wait } }

    public static func of(_ detail: PullDetail) -> GreenVerdict {
        var rules: [Rule] = []
        func rule(_ name: String, _ state: Rule.State, _ detail: String) {
            rules.append(Rule(name: name, state: state, detail: detail))
        }
        let base = detail.baseBranch.isEmpty ? "the base branch" : detail.baseBranch
        switch detail.state {
        case "MERGED": rule("Open", .fail, "merged")
        case "CLOSED": rule("Open", .fail, "closed without merging")
        default: rule("Open", .pass, "open")
        }
        if detail.isDraft == true {
            rule("Ready for review", .fail, "draft")
        } else {
            rule("Ready for review", .pass, "not a draft")
        }
        if detail.mergeable == "CONFLICTING" || detail.mergeState == "DIRTY" {
            rule("No conflicts", .fail, "conflicts with \(base)")
        } else if detail.mergeable == "MERGEABLE" {
            rule("No conflicts", .pass, "merges cleanly")
        } else {
            rule("No conflicts", .wait, "GitHub is still working it out")
        }
        if detail.mergeState == "BEHIND" {
            rule("Up to date", .fail, "behind \(base), which this repo requires to be current")
        } else {
            rule("Up to date", .pass, "current enough")
        }
        let required = detail.requiredChecks ?? []
        let failing = detail.failingChecks.map(\.name).filter { required.isEmpty || required.contains($0) }
        let pending = detail.checks.pendingNames.filter { required.isEmpty || required.contains($0) }
        let which = required.isEmpty ? "checks" : "required checks"
        if !failing.isEmpty {
            rule("Checks pass", .fail, "\(failing.joined(separator: ", ")) failed")
        } else if !pending.isEmpty {
            rule("Checks pass", .wait, "\(pending.joined(separator: ", ")) still running")
        } else {
            rule("Checks pass", .pass, detail.checks.total == 0 ? "no checks" : "all \(which) passed")
        }
        let open = detail.threads.count { !$0.isResolved }
        if open > 0 {
            rule("Threads resolved", .fail, "\(open) thread\(open == 1 ? "" : "s") open")
        } else {
            rule("Threads resolved", .pass, "none open")
        }
        if detail.reviewDecision == "CHANGES_REQUESTED" {
            rule("No changes requested", .fail, "a reviewer requested changes")
        } else {
            rule("No changes requested", .pass, "none outstanding")
        }
        return GreenVerdict(rules: rules)
    }
}
