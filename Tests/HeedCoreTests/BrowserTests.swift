import Foundation
@testable import HeedCore
import Testing

private func press(_ engine: inout ModeEngine, _ notation: String) -> [ModeEngine.Outcome] {
    // swiftlint:disable:next force_try
    try! KeyNotation.parse(notation).map { engine.handle($0) }
}

struct BrowserPaneTests {
    @Test func aPageKeepsItsAddressAcrossARelaunch() throws {
        let page = PaneSpec(role: .browser, title: "heed", directory: "/w", url: "https://github.com/o/heed")
        let decoded = try JSONDecoder().decode(PaneSpec.self, from: JSONEncoder().encode(page))
        #expect(decoded == page)
    }

    @Test func panesCachedBeforeBrowsersStillLoad() throws {
        let json = #"{"id":"p1","role":"shell","title":"zsh","directory":"/w"}"#
        let pane = try JSONDecoder().decode(PaneSpec.self, from: Data(json.utf8))
        #expect(pane.url == nil)
        #expect(pane.role == .shell)
    }
}

struct PageLayoutTests {
    private func layout() -> SessionLayout {
        let agent = PaneSpec(id: "agent", role: .agent, title: "claude", directory: "/w")
        let shell = PaneSpec(id: "shell", role: .shell, title: "zsh", directory: "/w")
        return SessionLayout(tabs: [
            PaneTab(id: "t1", title: "agent", tree: .leaf(agent)),
            PaneTab(id: "t2", title: "shell", tree: .leaf(shell)),
        ])
    }

    @Test func aNewPageOpensAtTheEndAndShows() {
        var layout = layout()
        let pane = layout.openPage("https://github.com/pulls", directory: "/w", show: true)
        #expect(layout.tabs.count == 3)
        #expect(layout.activeTab == 2)
        #expect(layout.tabs[2].tree.panes == [pane])
        #expect(pane.role == .browser)
        #expect(layout.tabs[2].title == "github.com")
    }

    @Test func aLinkOpensNextToItsPageAndStaysBehindWhenAsked() throws {
        var layout = layout()
        let page = layout.openPage("https://a.dev", directory: "/w", show: true)
        layout.activeTab = 2
        layout.openPage("https://b.dev", nextTo: page.id, directory: "/w", show: false)
        #expect(layout.tabs.map(\.title) == ["agent", "shell", "a.dev", "b.dev"])
        #expect(layout.activeTab == 2)
        // A link from the first tab lands right after it, and the tab you are on stays yours.
        let first = try #require(layout.tabs[0].tree.panes.first)
        layout.openPage("https://c.dev", nextTo: first.id, directory: "/w", show: false)
        #expect(layout.tabs.map(\.title) == ["agent", "c.dev", "shell", "a.dev", "b.dev"])
        #expect(layout.activeTab == 3)
    }

    @Test func aPageNamesItsTabWhenAlone() {
        var layout = layout()
        let page = layout.openPage(nil, directory: "/w", show: true)
        #expect(layout.tabs[2].title == "new page")
        layout.pageChanged(page.id, url: "https://github.com/o/heed", title: "o/heed")
        #expect(layout.tabs[2].title == "o/heed")
        #expect(layout.tabs[2].tree.panes[0].url == "https://github.com/o/heed")
        #expect(layout.contains(pane: page.id))
        // Split next to a shell, the tab keeps its own name.
        layout.tabs[1].split(.horizontal, with: PaneSpec(id: "web", role: .browser, title: "", directory: "/w"))
        layout.pageChanged("web", url: "http://localhost:3000", title: "Docs")
        #expect(layout.tabs[1].title == "shell")
        #expect(layout.tabs[1].tree.panes[1].title == "Docs")
    }
}

struct BrowserAddressTests {
    @Test func urlsStayAsTyped() {
        #expect(BrowserAddress.url(from: "https://github.com/o/r/pull/1") == "https://github.com/o/r/pull/1")
        #expect(BrowserAddress.url(from: "  http://localhost:4000/docs ") == "http://localhost:4000/docs")
        #expect(BrowserAddress.url(from: "about:blank") == "about:blank")
    }

    @Test func bareHostsBecomeURLs() {
        #expect(BrowserAddress.url(from: "github.com/o/r") == "https://github.com/o/r")
        #expect(BrowserAddress.url(from: "localhost:3000") == "http://localhost:3000")
        #expect(BrowserAddress.url(from: "127.0.0.1:8080/x") == "http://127.0.0.1:8080/x")
    }

    @Test func anythingElseIsASearch() {
        #expect(BrowserAddress.url(from: "swift observation") == "https://www.google.com/search?q=swift%20observation")
        #expect(BrowserAddress.url(from: "heed") == "https://www.google.com/search?q=heed")
        #expect(BrowserAddress.url(from: "mailto:me") == "https://www.google.com/search?q=mailto:me")
        #expect(BrowserAddress.url(from: "   ") == nil)
    }

    @Test func tabsAreNamedAfterThePage() {
        #expect(BrowserAddress.tabTitle(title: "Pull requests", url: "https://github.com/pulls") == "Pull requests")
        #expect(BrowserAddress.tabTitle(title: "", url: "https://github.com/pulls") == "github.com")
        #expect(BrowserAddress.tabTitle(title: "", url: nil) == "new page")
        #expect(BrowserAddress.tabTitle(title: String(repeating: "a", count: 40), url: nil).count == 28)
    }
}

struct BrowserKeyTests {
    private func engine() -> ModeEngine {
        let built = Keymaps.build()
        #expect(built.problems.isEmpty)
        return ModeEngine(keymaps: built.keymaps, scoped: built.scoped)
    }

    @Test func aPagesShortcutsWorkWhileTypingInIt() {
        var engine = engine()
        engine.paneScope = "browser"
        engine.enter(.insert)
        #expect(press(&engine, "<D-l>") == [.run(CommandInvocation(name: "browser.location"))])
        #expect(press(&engine, "<D-[>") == [.run(CommandInvocation(name: "browser.back"))])
        #expect(press(&engine, "<D-w>") == [.run(CommandInvocation(name: "pane.close"))])
        #expect(engine.mode == .insert)
        // Everything else is the page's, ⌘← and ⌘C included.
        #expect(press(&engine, "r") == [.terminal])
        #expect(press(&engine, "<D-Left>") == [.terminal])
        #expect(press(&engine, "<D-c>") == [.terminal])
        #expect(press(&engine, "<S-Esc>") == [.run(CommandInvocation(name: "mode.normal"))])
    }

    @Test func andInNormal() {
        var engine = engine()
        engine.paneScope = "browser"
        #expect(press(&engine, "<D-r>") == [.run(CommandInvocation(name: "browser.reload"))])
        #expect(press(&engine, "j") == [.run(CommandInvocation(name: "row.next"))])
    }

    @Test func onlyOnAPage() {
        var engine = engine()
        engine.enter(.insert)
        #expect(press(&engine, "<D-l>") == [.terminal])
        engine.enter(.normal)
        #expect(press(&engine, "<D-l>") == [.unbound([KeyStroke("l", .command)])])
        #expect(press(&engine, "<D-t>") == [.run(CommandInvocation(name: "browser.new"))])
    }

    @Test func pageBindingsAreSingleChords() {
        let built = Keymaps.build(scopedOverrides: ["browser": [("r", "browser.reload"), ("<C-r>", "browser.reload")]])
        #expect(built.problems.map(\.keys) == ["r"])
        #expect(built.scoped["browser"]?.lookup([KeyStroke("r", .control)]) == .command("browser.reload"))
    }
}
