@testable import HeedCore
import Testing

struct KibanaPageTests {
    private let url = "http://299433-fix.localhost/app/agent_builder"

    private func task(running: Bool, id: String = "t2") -> WorkTask {
        WorkTask(id: id, title: "Fix", worktree: "/w/299433-fix", port: 5602, running: running, kibanaURL: url)
    }

    @Test func oneStartIsOnePageNotOnePerProbe() {
        #expect(KibanaPage.started(by: [.taskUpserted(task(running: true))], in: [task(running: false)]) == ["t2"])
        // The next probe finds it still running: nothing.
        #expect(KibanaPage.started(by: [.taskUpserted(task(running: true))], in: [task(running: true)]).isEmpty)
        // Stopping is not a start, and neither is a task Heed didn't have before.
        #expect(KibanaPage.started(by: [.taskUpserted(task(running: false))], in: [task(running: true)]).isEmpty)
        #expect(KibanaPage.started(by: [.taskUpserted(task(running: true))], in: []).isEmpty)
    }

    @Test func noPageYetOpensOne() {
        #expect(KibanaPage.action(url: url, layout: nil) == .open(url: url))
        var layout = TaskLayout(tabs: [])
        layout.openPage("https://github.com/elastic/kibana/pull/1", directory: "/w", show: true)
        #expect(KibanaPage.action(url: url, layout: layout) == .open(url: url))
    }

    @Test func aRestartReloadsThePageOnItsHost() {
        var layout = TaskLayout(tabs: [])
        let other = layout.openPage("http://localhost:5602/app/discover", directory: "/w", show: true)
        let first = layout.openPage("http://299433-fix.localhost/app/discover#/view/1", directory: "/w", show: true)
        let second = layout.openPage(url, directory: "/w", show: true)
        #expect(other.id != first.id && first.id != second.id)
        // Only the first page on the task's Kibana host counts, wherever in Kibana it is.
        #expect(KibanaPage.action(url: url, layout: layout) == .reload(pane: first.id))
    }

    @Test func aClosedPageComesBackOnlyOnTheNextStart() {
        var layout = TaskLayout(tabs: [])
        let page = layout.openPage(url, directory: "/w", show: false)
        let removed = layout.removePane(page.id)
        #expect(removed)
        // Kibana still running: no start, so no page.
        #expect(KibanaPage.started(by: [.taskUpserted(task(running: true))], in: [task(running: true)]).isEmpty)
        // Next start: a page again.
        #expect(KibanaPage.action(url: url, layout: layout) == .open(url: url))
    }

    @Test func noURLDoesNothing() {
        #expect(KibanaPage.action(url: nil, layout: nil) == nil)
        #expect(KibanaPage.action(url: "not a url", layout: nil) == nil)
    }

    @Test func originsFillInThePort() {
        #expect(KibanaPage.origin("http://localhost/app/agent_builder") == "http://localhost:80")
        #expect(KibanaPage.origin("HTTP://Kibana.localhost:80/x") == "http://kibana.localhost:80")
        #expect(KibanaPage.origin("http://localhost:5602") != KibanaPage.origin("http://localhost:5603"))
    }
}
