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
        #expect(!decoded.role.isTerminal)
    }

    @Test func panesCachedBeforePagesStillLoad() throws {
        let json = #"{"id":"p1","role":"shell","title":"zsh","directory":"/w"}"#
        let pane = try JSONDecoder().decode(PaneSpec.self, from: Data(json.utf8))
        #expect(pane.url == nil)
        #expect(pane.role == .shell)
    }

    @Test func theTasksFixtureHasAKibanaPage() throws {
        let layout = try #require(Fixtures.tasks.layouts["t2"])
        let page = try #require(layout.panes.first { $0.role == .browser })
        #expect(page.url == "http://299433-fix-image-upload-403.localhost/app/agent_builder")
    }
}

struct PageLayoutTests {
    /// The agent in a pane on the left, a shell in the work pane on the right; the agent has the keys.
    private func layout() -> TaskLayout {
        let agent = PaneSpec(id: "agent", role: .agent, title: "claude", directory: "/w")
        let shell = PaneSpec(id: "shell", role: .shell, title: "zsh", directory: "/w")
        return TaskLayout(
            root: .split(
                .horizontal, .leaf(PaneGroup(id: "left", tabs: [PaneTab(id: "t1", title: "agent", pane: agent)])),
                .leaf(PaneGroup(id: "right", tabs: [PaneTab(id: "t2", title: "shell", pane: shell)])), ratio: 0.5
            ),
            focusedGroup: "left"
        )
    }

    private func titles(_ layout: TaskLayout) -> [[String]] { layout.groups.map { $0.tabs.map(\.title) } }

    @Test func aNewPageOpensInTheWorkPaneAndShows() {
        var layout = layout()
        let pane = layout.openPage("https://github.com/pulls", directory: "/w", show: true)
        #expect(titles(layout) == [["agent"], ["shell", "github.com"]])
        #expect(layout.focusedPane == pane)
        #expect(pane.role == .browser)
    }

    @Test func aPageOpenedBehindLeavesEveryActiveTab() {
        var layout = layout()
        layout.openPage("http://kibana.localhost/app/agent_builder", directory: "/w", show: false)
        #expect(titles(layout) == [["agent"], ["shell", "kibana.localhost"]])
        #expect(layout.focused?.id == "left")
        #expect(layout.groups[1].active?.title == "shell")
    }

    @Test func aLinkOpensNextToItsPageAndStaysBehindWhenAsked() {
        var layout = layout()
        let page = layout.openPage("https://a.dev", directory: "/w", show: true)
        layout.openPage("https://b.dev", nextTo: page.id, directory: "/w", show: false)
        layout.focus(pane: "shell")
        layout.openPage("https://c.dev", nextTo: "shell", directory: "/w", show: false)
        #expect(titles(layout) == [["agent"], ["shell", "c.dev", "a.dev", "b.dev"]])
        #expect(layout.focusedPane?.id == "shell")
    }

    @Test func aPageNamesItsTab() {
        var layout = layout()
        let page = layout.openPage(nil, directory: "/w", show: true)
        #expect(layout.groups[1].tabs[1].title == "new page")
        layout.pageChanged(page.id, url: "https://github.com/o/heed", title: "o/heed")
        #expect(layout.groups[1].tabs[1].title == "o/heed")
        #expect(layout.pane(page.id)?.url == "https://github.com/o/heed")
        #expect(layout.contains(pane: page.id))
    }

    @Test func closingAPageTakesItsTab() {
        var layout = layout()
        let page = layout.openPage("https://a.dev", directory: "/w", show: true)
        let removed = layout.removePane(page.id)
        #expect(removed)
        #expect(titles(layout) == [["agent"], ["shell"]])
        #expect(!layout.contains(pane: page.id))
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

    @Test func caddyHostsArePlainHTTP() {
        #expect(
            BrowserAddress.url(from: "299433-fix-image-upload-403.localhost/app/agent_builder")
                == "http://299433-fix-image-upload-403.localhost/app/agent_builder"
        )
        #expect(BrowserAddress.url(from: "Kibana.LOCALHOST") == "http://Kibana.LOCALHOST")
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
        #expect(press(&engine, "<D-]>") == [.run(CommandInvocation(name: "browser.forward"))])
        #expect(press(&engine, "<D-r>") == [.run(CommandInvocation(name: "browser.reload"))])
        #expect(press(&engine, "<D-=>") == [.run(CommandInvocation(name: "browser.zoom.in"))])
        #expect(press(&engine, "<D-->") == [.run(CommandInvocation(name: "browser.zoom.out"))])
        #expect(press(&engine, "<D-w>") == [.run(CommandInvocation(name: "tab.close"))])
        #expect(press(&engine, "<D-t>") == [.run(CommandInvocation(name: "tab.open"))])
        #expect(engine.mode == .insert)
        // Everything else is the page's: letters, ⌘← and ⌘C, and ⌘0 (never a ⌘+number key).
        #expect(press(&engine, "r") == [.terminal])
        #expect(press(&engine, "<D-Left>") == [.terminal])
        #expect(press(&engine, "<D-c>") == [.terminal])
        #expect(press(&engine, "<D-0>") == [.terminal])
        #expect(press(&engine, "<S-Esc>") == [.run(CommandInvocation(name: "mode.normal"))])
    }

    @Test func andInNormal() {
        var engine = engine()
        engine.paneScope = "browser"
        #expect(press(&engine, "<D-r>") == [.run(CommandInvocation(name: "browser.reload"))])
        // ⌘W closes only the tab you type in.
        #expect(press(&engine, "<D-w>") == [.unbound([KeyStroke("w", .command)])])
        #expect(press(&engine, "j") == [.run(CommandInvocation(name: "row.next"))])
        #expect(press(&engine, "gt") == [.pending, .run(CommandInvocation(name: "tab.next"))])
    }

    @Test func onlyOnAPage() {
        var engine = engine()
        engine.enter(.insert)
        #expect(press(&engine, "<D-l>") == [.terminal])
        #expect(press(&engine, "<D-w>") == [.run(CommandInvocation(name: "tab.close"))])
        // ⌘T asks what to open, and ⌘D ⌘⇧D split, from a terminal too.
        #expect(press(&engine, "<D-t>") == [.run(CommandInvocation(name: "tab.open"))])
        #expect(press(&engine, "<D-d>") == [.run(CommandInvocation(name: "pane.split.right"))])
        #expect(press(&engine, "<D-D>") == [.run(CommandInvocation(name: "pane.split.below"))])
        #expect(engine.mode == .insert)
        engine.enter(.normal)
        #expect(press(&engine, "<D-l>") == [.unbound([KeyStroke("l", .command)])])
        #expect(press(&engine, "<D-t>") == [.run(CommandInvocation(name: "tab.open"))])
        #expect(press(&engine, "<D-d>") == [.run(CommandInvocation(name: "pane.split.right"))])
        // ⌘⇧D comes from AppKit as ⌘ and a capital D.
        #expect(KeyStroke("D", [.command, .shift]) == KeyStroke("D", .command))
        #expect(press(&engine, "<D-D>") == [.run(CommandInvocation(name: "pane.split.below"))])
    }

    @Test func noCommandNumberKeys() {
        let built = Keymaps.build()
        let tables = Mode.allCases.compactMap { built.keymaps[$0] } + built.scoped.values
        for keymap in tables {
            for binding in keymap.bindings where binding.keys.contains(where: {
                $0.modifiers.contains(.command) && Int($0.key) != nil
            }) {
                Issue.record("\(KeyNotation.format(binding.keys)) is bound to \(binding.command)")
            }
        }
    }

    @Test func pageBindingsAreSingleChords() {
        let built = Keymaps.build(scopedOverrides: ["browser": [("r", "browser.reload"), ("<C-r>", "browser.reload")]])
        #expect(built.problems.map(\.keys) == ["r"])
        #expect(built.scoped["browser"]?.lookup([KeyStroke("r", .control)]) == .command("browser.reload"))
    }

    @Test func configTakesBrowserKeys() {
        let (config, problems) = ConfigLoader.decode("""
        [keys.browser]
        "<D-0>" = "browser.zoom.reset"
        """)
        #expect(problems.isEmpty)
        #expect(config?.scopedKeys["browser"]?.first?.1 == "browser.zoom.reset")
    }
}

struct NewTabPickerTests {
    @Test func aKeyPicksAKindAndReturnRepeatsTheLastOne() {
        let picker = NewTabPicker(last: .page)
        #expect(picker.handle(KeyStroke("t")) == .open(.terminal))
        #expect(picker.handle(KeyStroke("b")) == .open(.page))
        #expect(picker.handle(KeyStroke("CR")) == .open(.page))
        #expect(NewTabPicker(last: .terminal).handle(KeyStroke("t", .command)) == .open(.terminal))
        #expect(picker.handle(.escape) == .cancel)
        #expect(picker.handle(KeyStroke("q")) == .cancel)
        #expect(picker.handle(KeyStroke("x")) == .handled)
        #expect(picker.handle(KeyStroke("t", .control)) == .handled)
    }

    @Test func aPageOpensInThePaneYouChose() {
        let agent = PaneTab(title: "agent", pane: PaneSpec(id: "agent", role: .agent, title: "claude", directory: "/w"))
        var layout = TaskLayout(tabs: [agent])
        layout.add(
            PaneTab(title: "shell", pane: PaneSpec(id: "shell", role: .shell, title: "zsh", directory: "/w")),
            show: false
        )
        let left = layout.groups[0].id
        layout.openPage(nil, directory: "/w", show: true, in: left)
        #expect(layout.groups.map { $0.tabs.map(\.title) } == [["agent", "new page"], ["shell"]])
        #expect(layout.focused?.id == left)
    }
}
