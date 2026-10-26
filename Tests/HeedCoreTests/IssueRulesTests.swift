import Foundation
@testable import HeedCore
import Testing

struct IssueRulesTests {
    private let work = Repo(org: "employer", name: "service")
    private let oss = Repo(org: "nullean", name: "mermaider")

    private func issue(_ repo: Repo, _ number: Int, age: TimeInterval = 0) -> HeedCore.Issue {
        HeedCore.Issue(
            repo: repo, number: number, title: "#\(number)", url: "", body: "", labels: [], author: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000_000 - age)
        )
    }

    @Test func aReposOwnSettingWins() {
        let rules = IssueRules(fallback: .involved, repos: ["nullean/mermaider": .all])
        #expect(rules.visibility(work) == .involved)
        #expect(rules.visibility(oss) == .all)
    }

    @Test func reposShowingAllAreSearchedByRepo() {
        let rules = IssueRules(repos: ["nullean/extra": .all, "employer/docs": .all, "nullean/noisy": .involved])
        #expect(rules.watchQualifiers(local: [work, oss]) == ["repo:employer/docs", "repo:nullean/extra"])
    }

    @Test func anAllFallbackWatchesLocalReposWithoutTheirOwnSetting() {
        let rules = IssueRules(fallback: .all, repos: ["employer/service": .involved])
        #expect(rules.watchQualifiers(local: [work, oss]) == ["repo:nullean/mermaider"])
    }

    @Test func longQualifierListsAreSplitUnderGitHubsLimit() {
        let qualifiers = (1 ... 40).map { "repo:some-org/repository-\($0)" }
        let queries = GitHub.watchQueries(base: "is:open is:issue archived:false", qualifiers: qualifiers)
        #expect(queries.count > 1)
        #expect(queries.allSatisfy { $0.count <= 230 })
        #expect(queries.allSatisfy { $0.hasPrefix("is:open is:issue archived:false repo:") })
        #expect(queries.count <= 8)
    }

    @Test func mergingFlagsHowAnIssueInvolvesYou() {
        let merged = GitHub.mergeIssues(
            assigned: [issue(oss, 1, age: 10)],
            mentioned: [issue(oss, 1, age: 10), issue(work, 2, age: 5)],
            watched: [issue(oss, 1, age: 10), issue(oss, 3, age: 1)]
        )
        #expect(merged.map(\.number) == [3, 2, 1])
        #expect(merged.first { $0.number == 1 }.map { $0.assigned && $0.mentioned } == true)
        #expect(merged.first { $0.number == 2 }.map { !$0.assigned && $0.mentioned } == true)
        #expect(merged.first { $0.number == 3 }?.involvesYou == false)
    }

    @Test func configReadsIssueSettings() {
        let (config, problems) = ConfigLoader.decode("""
        [issues]
        default = "involved"
        [repos."nullean/noisy"]
        issues = "involved"
        [repos."employer/x"]
        issues = "sometimes"
        """)
        #expect(config?.issues.repos == ["nullean/noisy": .involved])
        #expect(problems.map(\.path) == ["repos.employer/x.issues"])
    }
}
