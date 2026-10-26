import Foundation

/// A PR as the reader shows it: description, review threads with the diff they refer to, checks, linked issues.
/// Fetched on demand and for the PRs of tasks.
public struct PullDetail: Hashable, Sendable, Codable {
    public var ref: PullRef
    public var title: String
    public var body: String
    public var author: String?
    public var baseBranch: String
    public var headBranch: String
    public var additions: Int
    public var deletions: Int
    public var commitCount: Int
    public var headSHA: String
    public var reviews: [Review]
    public var threads: [ReviewThread]
    public var failingChecks: [FailingCheck]
    public var checks: CheckSummary
    public var closes: [PullRef]
    public var fetchedAt: Date
    /// What the green verdict reads. Optional: details cached before them decode without them, and count as unknown.
    /// `OPEN`, `MERGED`, `CLOSED`.
    public var state: String?
    public var isDraft: Bool?
    /// `MERGEABLE`, `CONFLICTING`, or `UNKNOWN` while GitHub works it out.
    public var mergeable: String?
    /// GitHub's `mergeStateStatus`: `CLEAN`, `BEHIND` (out of date, and the repo requires up to date), `DIRTY`
    /// (conflicts), `BLOCKED`, `UNSTABLE`, `HAS_HOOKS`, `DRAFT`, `UNKNOWN`.
    public var mergeState: String?
    /// `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or nil.
    public var reviewDecision: String?
    /// The checks branch protection requires on this PR; empty when it requires none.
    public var requiredChecks: [String]?

    /// PRs that mention this one (GitHub's cross-references), for follow-ups and companion changes.
    public var references: [Reference]?

    public struct Reference: Hashable, Sendable, Codable {
        public var ref: PullRef
        public var title: String
        public var author: String?
        public var state: String
        public var createdAt: Date?

        public init(ref: PullRef, title: String, author: String?, state: String, createdAt: Date?) {
            self.ref = ref
            self.title = title
            self.author = author
            self.state = state
            self.createdAt = createdAt
        }
    }

    public struct Review: Hashable, Sendable, Codable {
        public var author: String
        public var state: String
        public var submittedAt: Date?
        /// The commit it reviewed, so a review from before the last push does not count.
        public var commit: String?

        public init(author: String, state: String, submittedAt: Date? = nil, commit: String? = nil) {
            self.author = author
            self.state = state
            self.submittedAt = submittedAt
            self.commit = commit
        }
    }

    public struct FailingCheck: Hashable, Sendable, Codable {
        public var name: String
        /// The check's title or summary, first line: `docs/redirects.md:41 line too long`.
        public var summary: String
        public var url: String?
    }

    public init(
        ref: PullRef, title: String, body: String, author: String?, baseBranch: String, headBranch: String,
        additions: Int, deletions: Int, commitCount: Int, headSHA: String, reviews: [Review], threads: [ReviewThread],
        failingChecks: [FailingCheck], checks: CheckSummary, closes: [PullRef], fetchedAt: Date
    ) {
        self.ref = ref
        self.title = title
        self.body = body
        self.author = author
        self.baseBranch = baseBranch
        self.headBranch = headBranch
        self.additions = additions
        self.deletions = deletions
        self.commitCount = commitCount
        self.headSHA = headSHA
        self.reviews = reviews
        self.threads = threads
        self.failingChecks = failingChecks
        self.checks = checks
        self.closes = closes
        self.fetchedAt = fetchedAt
    }

    public var approvals: Int { latestReviews.count { $0.state == "APPROVED" } }

    /// The last review per reviewer.
    public var latestReviews: [Review] {
        var seen: [String: Review] = [:]
        for review in reviews {
            seen[review.author] = review
        }
        return seen.values.sorted { $0.author < $1.author }
    }
}

public struct ReviewThread: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var isResolved: Bool
    public var path: String
    public var line: Int?
    public var author: String
    public var body: String
    /// The last lines of the diff hunk the thread is on.
    public var diff: [String]
    public var replies: Int
    public var url: String?

    public init(
        id: String, isResolved: Bool, path: String, line: Int?, author: String, body: String, diff: [String],
        replies: Int, url: String?
    ) {
        self.id = id
        self.isResolved = isResolved
        self.path = path
        self.line = line
        self.author = author
        self.body = body
        self.diff = diff
        self.replies = replies
        self.url = url
    }

    /// `RedirectFile.cs:88`.
    public var location: String {
        let file = (path as NSString).lastPathComponent
        return line.map { "\(file):\($0)" } ?? file
    }
}
