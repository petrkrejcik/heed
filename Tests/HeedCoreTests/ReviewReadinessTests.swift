import Foundation
@testable import HeedCore
import Testing

struct ReviewReadinessTests {
    private let ref = PullRef(repo: Kibana.repo, number: 123)

    private func pull(_ state: PullRequest.State = .open, draft: Bool, number: Int = 123) -> PullRequest {
        let ref = PullRef(repo: Kibana.repo, number: number)
        return PullRequest(
            ref: ref, title: "t", url: ref.url, state: state, isDraft: draft, headBranch: "b", review: nil,
            checks: CheckSummary(), unresolvedThreads: 0, updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func task(_ id: String = "a", _ status: TaskStatus = .inProgress, number: Int? = 123) -> WorkTask {
        WorkTask(id: id, title: id, status: status, pr: number.map { PullRef(repo: Kibana.repo, number: $0).url })
    }

    private func moved(_ before: [PullRequest], _ after: [PullRequest], _ tasks: [WorkTask]) -> [String] {
        ReviewReadiness.opened(before: before, after: after, tasks: tasks).map(\.id)
    }

    @Test func aPRSeenForTheFirstTimeIsTheBaseline() {
        // The first sync ever, or a PR just tracked: already open for review, but nothing changed.
        #expect(moved([], [pull(draft: false)], [task()]).isEmpty)
        #expect(moved([pull(draft: true, number: 9)], [pull(draft: false)], [task()]).isEmpty)
    }

    @Test func draftToReadyMovesTheTaskOnce() {
        let draft = [pull(draft: true)]
        let ready = [pull(draft: false)]
        #expect(moved(draft, ready, [task()]) == ["a"])
        // The next sync sees it ready again: no change, no second call.
        #expect(moved(ready, ready, [task()]).isEmpty)
        // A reopened PR (not a draft) counts as opened for review too.
        #expect(moved([pull(.closed, draft: false)], ready, [task()]) == ["a"])
    }

    @Test func aTaskMovedBackToInProgressByHandStaysThere() {
        // Petr set it back to In Progress to address review comments; the PR stays open and ready.
        let ready = [pull(draft: false)]
        #expect(moved(ready, ready, [task()]).isEmpty)
    }

    @Test func onlyInProgressTasksAreMoved() {
        let others: [TaskStatus] = [.toDo, .blocked, .readyForReview, .done, .dropped, TaskStatus(rawValue: "Paused")]
        let tasks = others.enumerated().map { task("t\($0.offset)", $0.element) }
        #expect(moved([pull(draft: true)], [pull(draft: false)], tasks).isEmpty)
    }

    @Test func onlyAPRBecomingReadyCounts() {
        #expect(moved([pull(draft: false)], [pull(draft: true)], [task()]).isEmpty)
        #expect(moved([pull(draft: true)], [pull(.merged, draft: false)], [task()]).isEmpty)
        // Also what an offline sync looks like: it keeps the previous PRs.
        #expect(moved([pull(draft: true)], [pull(draft: true)], [task()]).isEmpty)
    }

    @Test func onlyTheTasksLinkedToThatPR() {
        let tasks = [task("mine"), task("other", number: 456), task("none", number: nil)]
        #expect(moved([pull(draft: true)], [pull(draft: false)], tasks) == ["mine"])
    }

    @Test func afterARelaunchTheCachedSyncIsThePreviousOne() async throws {
        // Heed quit with the PR a draft; it was marked ready while Heed was closed.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("heed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = DomainStore(file: file, writeDelay: .zero)
        await store.apply([.taskUpserted(task()), .githubSynced(GitHubState(pulls: [pull(draft: true)]))])
        await store.flush()
        let cached = await DomainStore.load(from: file)
        #expect(moved(cached.github.pulls, [pull(draft: false)], cached.tasks) == ["a"])
    }
}

struct ReadyBridgeTests {
    @Test func syncAndReadyDecodeWhatPkSends() async throws {
        let synced = """
        {"version":1,"id":"x","type":"result","data":{"linked":[{"id":"t-1","title":"Fix","status":"Ready for Review",\
        "pinned":false,"pr":"https://github.com/elastic/kibana/pull/7","port":null,"running":false}],"errors":{},\
        "ready":["t-1"]}}
        """
        let older = """
        {"version":1,"id":"x","type":"result","data":{"linked":[],"errors":{}}}
        """
        let ready = """
        {"version":1,"id":"x","type":"result","data":{"task":{"id":"t-1","title":"Fix","status":"In Progress",\
        "pinned":false,"port":null,"running":false},"moved":false,"detail":"PR #7 is a draft"}}
        """
        func bridge(_ stdout: String) -> PkBridge {
            PkBridge(python: "/p") { _ in ProcessResult(status: 0, stdout: stdout, stderr: "") }
        }
        let sync = try await bridge(synced).syncPRs("t-1")
        #expect(sync.ready == ["t-1"] && sync.linked.map(\.status) == ["Ready for Review"])
        #expect(try await bridge(older).syncPRs("t-1").ready.isEmpty)
        let result = try await bridge(ready).markReady("t-1")
        #expect(!result.moved && result.detail == "PR #7 is a draft" && result.task.status == "In Progress")
    }

    @Test func theFakeMovesOnlyInProgressWithAPR() async throws {
        let pr = PullRef(repo: Kibana.repo, number: 7).url
        let fake = FakePk(tasks: [
            WorkTask(id: "a", title: "A", pr: pr), WorkTask(id: "b", title: "B", status: .blocked, pr: pr),
            WorkTask(id: "c", title: "C"),
        ])
        let moved = try await fake.bridge.markReady("a")
        #expect(moved.moved && moved.task.status == "Ready for Review" && moved.detail == "PR #7 is open")
        #expect(try await !fake.bridge.markReady("b").moved)
        #expect(try await fake.bridge.markReady("c").detail == "no PR linked")
        #expect(try await fake.bridge.syncPRs("c") == PkPullSync(linked: []))
    }
}
