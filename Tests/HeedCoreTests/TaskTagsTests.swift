import Foundation
@testable import HeedCore
import Testing

private let now = Date(timeIntervalSince1970: 1_000_000)
private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

private let ref = PullRef(repo: Repo(org: "elastic", name: "kibana"), number: 42)

private func pull(
    state: PullRequest.State = .open, draft: Bool = false, checks: CheckSummary = CheckSummary(passed: 1),
    threads: Int = 0
) -> PullRequest {
    PullRequest(
        ref: ref, title: "t", url: ref.url, state: state, isDraft: draft, headBranch: "b", review: nil,
        checks: checks, unresolvedThreads: threads, updatedAt: now
    )
}

private func detail(
    state: String = "OPEN", draft: Bool? = false, mergeable: String = "MERGEABLE", failing: [String] = []
) -> PullDetail {
    var detail = PullDetail(
        ref: ref, title: "t", body: "", author: nil, baseBranch: "main", headBranch: "b", additions: 0,
        deletions: 0, commitCount: 1, headSHA: "a1", reviews: [], threads: [],
        failingChecks: failing.map { PullDetail.FailingCheck(name: $0, summary: "", url: nil) },
        checks: CheckSummary(passed: 1, failed: failing.count, failedNames: failing), closes: [], fetchedAt: now
    )
    detail.state = state
    detail.isDraft = draft
    detail.mergeable = mergeable
    detail.mergeState = mergeable == "CONFLICTING" ? "DIRTY" : "CLEAN"
    return detail
}

private func agent(_ state: AgentState, turn minutes: Double?) -> AgentTab {
    AgentTab(state: ObservedState(state), lastTurnAt: minutes.map(ago))
}

struct PromptCacheTests {
    @Test func countsDownAnHourFromTheLastTurn() throws {
        #expect(PromptCache.ttl == 3600)
        let countdown = try #require(PromptCache.countdown(from: ago(15), now: now))
        #expect(countdown.minutesLeft == 45)
        #expect(countdown.expiresAt == ago(15).addingTimeInterval(3600))
        #expect(!countdown.isWarning)
        // Rounded up: 44.5 minutes left still says 45, the last seconds say 1.
        #expect(PromptCache.countdown(from: ago(15.5), now: now)?.minutesLeft == 45)
        #expect(PromptCache.countdown(from: ago(59.9), now: now)?.minutesLeft == 1)
        // Just ended, or stamped a little ahead by the hook: a full hour.
        #expect(PromptCache.countdown(from: now, now: now)?.minutesLeft == 60)
        #expect(PromptCache.countdown(from: now.addingTimeInterval(30), now: now)?.minutesLeft == 60)
    }

    @Test func goneOnceExpired() {
        #expect(PromptCache.countdown(from: ago(60), now: now) == nil)
        #expect(PromptCache.countdown(from: ago(60 * 26), now: now) == nil)
    }

    @Test func amberAtFiveMinutesOrLess() {
        #expect(PromptCache.countdown(from: ago(55), now: now)?.isWarning == true)
        #expect(PromptCache.countdown(from: ago(54.5), now: now)?.isWarning == false)
        #expect(PromptCache.countdown(from: ago(57), now: now)?.isWarning == true)
    }

    @Test func ofSeveralTheSoonestToExpireThatHasNot() {
        #expect(PromptCache.countdown(turns: [ago(10), ago(50), ago(70)], now: now)?.minutesLeft == 10)
        #expect(PromptCache.countdown(turns: [ago(70)], now: now) == nil)
        #expect(PromptCache.countdown(turns: [], now: now) == nil)
    }

    @Test func onlyAgentsWhoseTurnIsOverCount() {
        #expect(PromptCache.turnEnded(agent(.idle, turn: 5)) == ago(5))
        #expect(PromptCache.turnEnded(agent(.done, turn: 5)) == ago(5))
        for state in [AgentState.working, .asking, .blocked, .limited, .exited] {
            #expect(PromptCache.turnEnded(agent(state, turn: 5)) == nil)
        }
        #expect(PromptCache.turnEnded(agent(.idle, turn: nil)) == nil)
    }

    @Test func onlyAFinishedTurnRestartsTheCountdown() {
        let at = now
        let previous = ago(51)
        #expect(PromptCache.lastTurn(after: .done, reason: nil, at: at, previous: previous) == at)
        // A failed turn (StopFailure) got no response.
        #expect(PromptCache.lastTurn(after: .done, reason: "server_error", at: at, previous: previous) == previous)
        // Resuming at launch, or the idle notice a minute after a turn, is no response either.
        #expect(PromptCache.lastTurn(after: .idle, reason: "resume", at: at, previous: previous) == previous)
        #expect(PromptCache.lastTurn(after: .idle, reason: nil, at: at, previous: previous) == previous)
        for state in [AgentState.working, .asking, .blocked, .limited, .exited] {
            #expect(PromptCache.lastTurn(after: state, reason: nil, at: at, previous: previous) == previous)
        }
        // A new, cleared or compacted conversation has no cache yet.
        for source in ["startup", "clear", "compact"] {
            #expect(PromptCache.lastTurn(after: .idle, reason: source, at: at, previous: previous) == nil)
        }
    }

    @Test func theRollupKeepsTheEndedTurnsOfItsAgentTabs() {
        let task = WorkTask(id: "t", title: "t")
        let tabs = ["a", "b", "c"].map { id in
            PaneTab(title: id, pane: PaneSpec(id: "t-\(id)", role: .agent, title: "claude", directory: "/"))
        }
        let agents = ["t-a": agent(.working, turn: 3), "t-b": agent(.idle, turn: 20), "t-c": agent(.done, turn: 50)]
        let rollup = TaskRollup.of(task, layout: TaskLayout(tabs: tabs), agents: agents)
        #expect(rollup.cacheTurns == [ago(20), ago(50)])
        // The working agent refreshes its own cache; of the others, the one about to go.
        #expect(PromptCache.countdown(turns: rollup.cacheTurns, now: now)?.minutesLeft == 10)
    }
}

struct PullTagTests {
    @Test func theStateFromTheSyncOrTheDetails() {
        #expect(PullTag.of(ref, pull: pull(), detail: nil).state == .open)
        #expect(PullTag.of(ref, pull: pull(draft: true), detail: nil).state == .draft)
        #expect(PullTag.of(ref, pull: pull(state: .merged), detail: nil).state == .merged)
        #expect(PullTag.of(ref, pull: pull(state: .closed), detail: nil).state == .closed)
        #expect(PullTag.of(ref, pull: nil, detail: detail(draft: true)).state == .draft)
        #expect(PullTag.of(ref, pull: nil, detail: detail(state: "MERGED")).state == .merged)
        #expect(PullTag.of(ref, pull: nil, detail: detail(state: "CLOSED")).state == .closed)
        #expect(PullTag.of(ref, pull: nil, detail: detail(draft: nil)).state == .open)
        // The details are fetched for the task's PR, so they win over the sync's summary.
        #expect(PullTag.of(ref, pull: pull(draft: true), detail: detail(draft: false)).state == .open)
        // Merged or closed by either: it is.
        #expect(PullTag.of(ref, pull: pull(state: .merged), detail: detail()).state == .merged)
        // Nothing arrived yet: just the number.
        let unknown = PullTag.of(ref, pull: nil, detail: nil)
        #expect(unknown == PullTag(number: 42, state: nil))
    }

    @Test func theMarkOnlyWhenThereIsSomethingToActOn() {
        #expect(PullTag.of(ref, pull: nil, detail: detail()).alert == nil)
        #expect(PullTag.of(ref, pull: nil, detail: detail(failing: ["lint"])).alert == .failing(1))
        #expect(PullTag.of(ref, pull: nil, detail: detail(mergeable: "CONFLICTING")).alert == .conflicted(
            "conflicts with main"
        ))
        #expect(PullTag.of(ref, pull: pull(threads: 2), detail: nil).alert == .changes(2))
        #expect(PullTag.of(ref, pull: pull(checks: CheckSummary(pending: 1)), detail: nil).alert == nil)
        // A draft whose checks fail still says so.
        let draft = PullTag.of(ref, pull: nil, detail: detail(draft: true, failing: ["lint"]))
        #expect(draft.state == .draft)
        #expect(draft.alert == .failing(1))
        // Merged or closed: what its checks did no longer matters.
        #expect(PullTag.of(ref, pull: pull(state: .closed, checks: CheckSummary(failed: 1)), detail: nil).alert == nil)
    }
}

struct TaskTagTests {
    @Test func kibanaThenThePullThenTheCache() {
        let task = WorkTask(id: "t", title: "t", port: 5602, running: true)
        let rollup = TaskRollup(agent: nil, kibanaRunning: true, cacheTurns: [ago(15)])
        let pull = PullTag(number: 42, state: .open)
        let tags = TaskTag.of(task, rollup: rollup, pull: pull, now: now)
        let countdown = PromptCache.countdown(from: ago(15), now: now)!
        #expect(tags == [.kibana(port: 5602), .pull(pull), .cache(countdown)])
    }

    @Test func onlyTheTagsThatApply() {
        let stopped = WorkTask(id: "t", title: "t", port: 5602, running: false)
        #expect(TaskTag.of(stopped, rollup: TaskRollup(agent: nil), pull: nil, now: now).isEmpty)
        // Kibana listens but the task has no port of its own: nothing to show.
        let portless = WorkTask(id: "t", title: "t", running: true)
        #expect(TaskTag.of(portless, rollup: TaskRollup(agent: nil, kibanaRunning: true), pull: nil, now: now).isEmpty)
        // An expired cache is no tag.
        let cold = TaskRollup(agent: nil, cacheTurns: [ago(61)])
        #expect(TaskTag.of(stopped, rollup: cold, pull: nil, now: now).isEmpty)
    }

    @Test func theFixtureShowsEveryTag() {
        let domain = Fixtures.tasks
        let list = TaskList(domain.tasks, layouts: domain.layouts, agents: domain.agents)
        let tags = domain.tasks.flatMap { task in
            TaskTag.of(task, rollup: list.rollup(of: task.id), pull: task.pull.map { ref in
                PullTag.of(ref, pull: domain.github.pull(ref), detail: domain.pullDetails[ref.description])
            }, now: Clock.now)
        }
        #expect(tags.contains { if case .kibana = $0 { true } else { false } })
        let states = Set(tags.compactMap { if case let .pull(pull) = $0 { pull.state } else { nil } })
        #expect(states == [.draft, .open, .merged, .closed])
        let caches = tags.compactMap { if case let .cache(countdown) = $0 { countdown } else { nil } }
        #expect(caches.contains { !$0.isWarning })
        #expect(caches.contains { $0.isWarning })
    }
}
