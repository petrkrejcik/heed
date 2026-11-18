@testable import HeedCore
import Testing

private func pr(_ number: Int) -> PullRef { PullRef(repo: Repo(org: "elastic", name: "kibana"), number: number) }

struct PullPagesTests {
    @Test func showingMovesAPageToTheFront() {
        var pages = PullPages()
        #expect(pages.show(pr(1)).isEmpty)
        #expect(pages.show(pr(2)).isEmpty)
        #expect(pages.show(pr(1)).isEmpty)
        #expect(pages.recent == [pr(1), pr(2)])
    }

    @Test func pagesPastTheKeptOnesClose() {
        var pages = PullPages()
        for number in 1 ... PullPages.kept {
            #expect(pages.show(pr(number)).isEmpty)
        }
        #expect(pages.show(pr(99)) == [pr(1)])
        #expect(pages.recent.count == PullPages.kept)
        #expect(pages.recent.first == pr(99))
    }

    @Test func aPageIsAWebPageAtThePullsAddress() {
        let pane = PullPages.pane(pr(299_455))
        #expect(pane.role == .browser)
        #expect(pane.url == "https://github.com/elastic/kibana/pull/299455")
        #expect(PullPages.isPaneID(pane.id))
        #expect(pane.id != PullPages.paneID(pr(1)))
        #expect(!PullPages.isPaneID(PaneSpec(role: .browser, title: "", directory: "").id))
    }
}
