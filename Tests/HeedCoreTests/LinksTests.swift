import Foundation
@testable import HeedCore
import Testing

/// A task's links: its PR, its issue and the repo, and what gB does with them.
struct LinksTests {
    private let repo = Kibana.repo

    @Test func refsReadTheURLsPkSends() {
        #expect(IssueRef(url: "https://github.com/elastic/kibana/issues/5/") == IssueRef(repo: repo, number: 5))
        #expect(IssueRef(url: "https://github.com/elastic/kibana/pull/5") == nil)
        #expect(PullRef(url: "https://github.com/elastic/kibana/pull/299455")?.number == 299_455)
        #expect(TaskLink.repo(repo).url == "https://github.com/elastic/kibana")
        #expect(TaskLink.pull(PullRef(repo: repo, number: 1)).label == "kibana #1")
        #expect(IssueLinks.compareURL(repo: repo, branch: "fix/a b")
            == "https://github.com/elastic/kibana/compare/fix/a%20b?expand=1")
    }

    @Test func thePickerOpensOneByNumberOrAll() {
        let links: [TaskLink] = [.pull(PullRef(repo: repo, number: 1)), .issue(IssueRef(repo: repo, number: 2))]
        var picker = LinkPicker(title: "t", links: links)
        #expect(picker.handle(KeyStroke("2")) == .open([links[1]]))
        #expect(picker.handle(KeyStroke("5")) == .handled)
        #expect(picker.handle(KeyStroke("j")) == .handled)
        #expect(picker.cursor == 1)
        #expect(picker.handle(KeyStroke("j")) == .handled)
        #expect(picker.cursor == 1)
        #expect(picker.handle(KeyStroke("CR")) == .open([links[1]]))
        #expect(picker.handle(KeyStroke("a")) == .open(links))
        #expect(picker.handle(.escape) == .cancel)
    }

    @Test func heedIssueAddTakesOnlyAnIssueURL() throws {
        #expect(try HookCommandLine.parse(["issue", "add", "https://github.com/elastic/kibana/issues/3"])
            == [.issueAdd(url: "https://github.com/elastic/kibana/issues/3")])
        #expect(throws: HookCommandLine.UsageError.self) {
            try HookCommandLine.parse(["issue", "add", "https://github.com/elastic/kibana/pull/3"])
        }
    }
}
