import Foundation
@testable import HeedCore
import Testing

struct PullStatusTests {
    private let ref = PullRef(repo: Repo(org: "nullean", name: "heed"), number: 7)

    private func detail(
        mergeable: String? = "MERGEABLE", state: String? = "CLEAN", failing: [String] = [], pending: [String] = [],
        required: [String] = [], threads: Int = 0, review: String? = nil, draft: Bool = false, prState: String = "OPEN"
    ) -> PullDetail {
        var detail = PullDetail(
            ref: ref, title: "t", body: "", author: nil, baseBranch: "main", headBranch: "b", additions: 0,
            deletions: 0, commitCount: 1, headSHA: "a1", reviews: [],
            threads: (0 ..< threads).map {
                ReviewThread(
                    id: "T\($0)",
                    isResolved: false,
                    path: "f",
                    line: 1,
                    author: "r",
                    body: "x",
                    diff: [],
                    replies: 0,
                    url: nil
                )
            },
            failingChecks: failing.map { PullDetail.FailingCheck(name: $0, summary: "\($0) broke", url: nil) },
            checks: CheckSummary(
                passed: 2,
                failed: failing.count,
                pending: pending.count,
                failedNames: failing,
                pendingNames: pending
            ),
            closes: [], fetchedAt: Date()
        )
        detail.state = prState
        detail.isDraft = draft
        detail.mergeable = mergeable
        detail.mergeState = state
        detail.reviewDecision = review
        detail.requiredChecks = required
        return detail
    }

    private func status(_ detail: PullDetail) -> PullStatus { PullStatus.of(pull: nil, detail: detail) }

    private func pull(
        checks: CheckSummary = CheckSummary(passed: 1),
        threads: Int = 0,
        state: PullRequest.State = .open
    )
        -> PullRequest
    {
        PullRequest(
            ref: ref, title: "t", url: "", state: state, isDraft: false, headBranch: "b", review: nil,
            checks: checks, unresolvedThreads: threads, updatedAt: Date()
        )
    }

    @Test func greenWhenEveryRuleHolds() {
        let verdict = GreenVerdict.of(detail())
        #expect(verdict.isGreen)
        #expect(verdict.blocker == nil)
        #expect(status(detail()) == .green)
    }

    @Test func eachRuleHoldsItBack() {
        #expect(status(detail(mergeable: "CONFLICTING", state: "DIRTY")) == .conflicted("conflicts with main"))
        #expect(status(detail(state: "BEHIND")) == .conflicted("behind main, which this repo requires to be current"))
        #expect(status(detail(failing: ["lint"])) == .failing(1))
        #expect(status(detail(pending: ["build"])) == .pending)
        #expect(status(detail(threads: 2)) == .changes(2))
        #expect(status(detail(review: "CHANGES_REQUESTED")) == .changes(1))
        #expect(status(detail(draft: true)) == .draft)
        #expect(status(detail(prState: "MERGED")) == .closed(merged: true))
        // GitHub still working out mergeability: not green yet, but nothing failed either.
        #expect(status(detail(mergeable: "UNKNOWN", state: "UNKNOWN")) == .pending)
    }

    @Test func onlyRequiredChecksCountWhenThereAreAny() {
        let optional = detail(failing: ["label"], required: ["build"])
        #expect(GreenVerdict.of(optional).isGreen)
        #expect(status(detail(failing: ["build"], required: ["build"])) == .failing(1))
        #expect(GreenVerdict.of(detail(failing: ["label"])).blocker?.detail == "label failed")
    }

    @Test func withoutADetailTheSyncsSummaryDecides() {
        #expect(PullStatus.of(pull: pull()) == .passing)
        #expect(PullStatus.of(pull: pull(checks: CheckSummary(passed: 1, failed: 2))) == .failing(2))
        #expect(PullStatus.of(pull: pull(threads: 3)) == .changes(3))
        #expect(PullStatus.of(pull: pull(checks: CheckSummary(pending: 1))) == .pending)
        #expect(PullStatus.of(pull: pull(state: .merged)) == .closed(merged: true))
        #expect(PullStatus.of(pull: nil) == .pending)
        #expect(PullStatus.failing(1).urgency < PullStatus.changes(1).urgency)
    }

    @Test func theDetailQueryFieldsAreRead() throws {
        let json = """
        {"data":{"repository":{"pullRequest":{"number":7,"title":"t","body":"","baseRefName":"main","headRefName":"b",
          "additions":1,"deletions":1,"state":"OPEN","isDraft":false,"mergeable":"CONFLICTING",
          "mergeStateStatus":"DIRTY","reviewDecision":"APPROVED",
          "commits":{"totalCount":1,"nodes":[{"commit":{"oid":"a1","statusCheckRollup":{"contexts":{"nodes":[
            {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS","isRequired":true},
            {"__typename":"CheckRun","name":"label","status":"COMPLETED","conclusion":"FAILURE","isRequired":false},
            {"__typename":"StatusContext","context":"ci/legacy","state":"SUCCESS","isRequired":true}]}}}}]},
          "reviews":{"nodes":[]},"closingIssuesReferences":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
        """
        let detail = try #require(GitHub.parsePullDetail(Data(json.utf8), ref: ref, now: Date()))
        #expect(detail.mergeable == "CONFLICTING")
        #expect(detail.mergeState == "DIRTY")
        #expect(detail.reviewDecision == "APPROVED")
        #expect(detail.requiredChecks == ["build", "ci/legacy"])
        #expect(GreenVerdict.of(detail).blocker?.name == "No conflicts")
    }
}
