import Foundation
@testable import HeedCore
import Testing

private func spec(_ id: String, _ role: PaneSpec.Role = .shell) -> PaneSpec {
    PaneSpec(id: id, role: role, title: id, directory: "/w")
}

private func tab(_ id: String, _ role: PaneSpec.Role = .shell) -> PaneTab {
    PaneTab(id: "tab-\(id)", title: id, pane: spec(id, role))
}

/// The tab titles, pane by pane.
private func titles(_ layout: TaskLayout) -> [[String]] { layout.groups.map { $0.tabs.map(\.title) } }

/// The agent alone on the left, `work` on the right; the agent has the keys.
private func agentAndWork(_ work: [String]) -> TaskLayout {
    TaskLayout(
        root: .split(
            .horizontal, .leaf(PaneGroup(id: "left", tabs: [tab("agent", .agent)])),
            .leaf(PaneGroup(id: "right", tabs: work.map { tab($0) })), ratio: 0.5
        ),
        focusedGroup: "left"
    )
}

struct PaneTreeTests {
    private func group(_ id: String) -> PaneGroup { PaneGroup(id: id, tabs: [tab(id)]) }

    /// a | (b over c)
    private var tree: PaneTree {
        PaneTree.leaf(group("a")).splitting("a", axis: .horizontal, with: group("b"))
            .splitting("b", axis: .vertical, with: group("c"))
    }

    @Test func splitsAndReadingOrder() {
        #expect(tree.groups.map(\.id) == ["a", "b", "c"])
        #expect(tree.topRight.id == "b")
        #expect(PaneTree.leaf(group("a")).topRight.id == "a")
    }

    @Test func focusMovesAcrossSplits() {
        #expect(tree.neighbor(of: "a", .right) == "b")
        #expect(tree.neighbor(of: "c", .left) == "a")
        #expect(tree.neighbor(of: "c", .up) == "b")
        #expect(tree.neighbor(of: "b", .up) == nil)
        #expect(tree.neighbor(of: "a", .left) == nil)
    }

    @Test func aDraggedDividerSetsItsOwnSplitWithinBounds() {
        /// Every split's ratio, outer first.
        func ratios(_ tree: PaneTree) -> [Double] {
            guard case let .split(_, first, second, ratio) = tree else { return [] }
            return [ratio] + ratios(first) + ratios(second)
        }
        #expect(ratios(tree.settingRatio(0.3, at: [1])) == [0.5, 0.3])
        #expect(ratios(tree.settingRatio(1.4, at: [])) == [0.9, 0.5])
        #expect(ratios(tree.settingRatio(-1, at: [])) == [0.1, 0.5])
        #expect(tree.settingRatio(0.3, at: [1]).groups == tree.groups)
        #expect(tree.settingRatio(0.3, at: [0]) == tree)
        #expect(tree.settingRatio(0.3, at: [1, 1]) == tree)
        #expect(tree.settingRatio(0.3, at: [7]) == tree)
    }

    @Test func removingAPaneCollapsesToItsSibling() {
        #expect(tree.removing("b")?.groups.map(\.id) == ["a", "c"])
        #expect(PaneTree.leaf(group("a")).removing("a") == nil)
        #expect(tree.removing("nope") == tree)
    }
}

struct TabPlacementTests {
    @Test func aNewTabGoesToTheWorkPaneAndKeepsTheAgentInView() {
        var layout = agentAndWork(["shell"])
        layout.add(tab("jest"), show: true)
        #expect(titles(layout) == [["agent"], ["shell", "jest"]])
        #expect(layout.focusedPane?.id == "jest")
        // Focused on the work pane, the next one lands there too.
        layout.add(tab("kibana"), show: true)
        #expect(titles(layout) == [["agent"], ["shell", "jest", "kibana"]])
    }

    @Test func withOnlyTheAgentAWorkPaneOpensOnItsRight() {
        var layout = TaskLayout(tabs: [tab("agent", .agent)])
        layout.add(tab("shell"), show: false)
        #expect(titles(layout) == [["agent"], ["shell"]])
        #expect(layout.focusedPane?.id == "agent")
        guard case let .split(axis, _, _, ratio) = layout.root else {
            Issue.record("expected a split, got \(String(describing: layout.root))")
            return
        }
        #expect(axis == .horizontal)
        #expect(ratio == 0.5)
    }

    @Test func aTabShownWithoutFocusLeavesTheKeysWhereTheyAre() {
        var layout = agentAndWork(["shell"])
        layout.add(tab("bootstrap"), show: true, focus: false)
        #expect(layout.groups[1].active?.title == "bootstrap")
        #expect(layout.focusedPane?.id == "agent")
    }

    @Test func anAgentJoinsTheAgentsPaneElseGetsANewOneOnTheLeft() {
        var layout = agentAndWork(["shell"])
        layout.focus(pane: "shell")
        layout.add(tab("second", .agent), show: true)
        #expect(titles(layout) == [["agent", "second"], ["shell"]])
        #expect(layout.focusedPane?.id == "second")

        var without = TaskLayout(tabs: [tab("shell"), tab("jest")])
        without.add(tab("agent", .agent), show: true)
        #expect(titles(without) == [["agent"], ["shell", "jest"]])
        #expect(without.focusedPane?.id == "agent")
    }

    @Test func intoAPaneYouChose() {
        var layout = agentAndWork(["shell"])
        layout.add(tab("notes"), show: true, in: "left")
        #expect(titles(layout) == [["agent", "notes"], ["shell"]])
    }

    @Test func theFirstTabOfAnEmptyLayoutMakesItsOnlyPane() {
        var layout = TaskLayout()
        layout.add(tab("shell"), show: true)
        #expect(titles(layout) == [["shell"]])
        #expect(layout.focusedPane?.id == "shell")
    }

    @Test func worktreeTabsShowTheirFirstInEachPaneAndFocusTheAgent() {
        let added = [tab("bootstrap"), tab("jest"), tab("agent2", .agent)]
        let layout = NewTask.adding(added, to: agentAndWork(["shell"]), focus: "agent2")
        #expect(titles(layout) == [["agent", "agent2"], ["shell", "bootstrap", "jest"]])
        #expect(layout.groups[1].active?.title == "bootstrap")
        #expect(layout.focusedPane?.id == "agent2")
    }
}

struct TabMovingTests {
    @Test func withinAPaneTheActiveTabStaysTheSameTab() {
        var layout = TaskLayout(tabs: ["a", "b", "c", "d"].map { tab($0) }, activeTab: 1)
        layout.moveTab("tab-a", to: 2)
        #expect(titles(layout) == [["b", "c", "a", "d"]])
        #expect(layout.focusedPane?.id == "b")
        layout.moveTab("tab-d", to: 0)
        #expect(titles(layout) == [["d", "b", "c", "a"]])
        layout.moveTab("tab-c", to: 99)
        #expect(titles(layout) == [["d", "b", "a", "c"]])
        layout.moveTab("nope", to: 0)
        #expect(titles(layout) == [["d", "b", "a", "c"]])
        #expect(layout.focusedPane?.id == "b")
    }

    @Test func toAnotherPaneItShowsThereFocused() {
        var layout = agentAndWork(["shell", "jest"])
        layout.moveTab("tab-jest", to: 0, in: "left")
        #expect(titles(layout) == [["jest", "agent"], ["shell"]])
        #expect(layout.focusedPane?.id == "jest")
    }

    @Test func thePaneItLeftGoesWhenEmpty() {
        var layout = agentAndWork(["shell"])
        layout.moveTab("tab-shell", to: 1, in: "left")
        #expect(titles(layout) == [["agent", "shell"]])
        #expect(layout.groups.count == 1)
        #expect(layout.focusedPane?.id == "shell")
    }
}

struct TabClosingTests {
    @Test func closingATabKeepsTheActiveOneAndAnEmptyPaneGoes() {
        var layout = agentAndWork(["a", "b", "c"])
        layout.focus(pane: "c")
        layout.removePane("a")
        #expect(titles(layout) == [["agent"], ["b", "c"]])
        #expect(layout.focusedPane?.id == "c")
        layout.removePane("c")
        #expect(layout.focusedPane?.id == "b")
        layout.removePane("b")
        #expect(titles(layout) == [["agent"]])
        #expect(layout.focusedPane?.id == "agent")
        let missing = layout.removePane("nope")
        #expect(!missing)
        layout.removePane("agent")
        #expect(layout.isEmpty)
        #expect(layout.focused == nil)
    }

    @Test func closingAPaneHandsItsTabsToTheOneBeside() {
        var layout = agentAndWork(["shell", "jest"])
        layout.focus(pane: "jest")
        let closed = layout.closeFocusedGroup()
        #expect(closed)
        #expect(titles(layout) == [["agent", "shell", "jest"]])
        #expect(layout.focusedPane?.id == "jest")
        let onlyPane = layout.closeFocusedGroup()
        #expect(!onlyPane)
        // The first pane's tabs go to the pane after it.
        var first = agentAndWork(["shell"])
        let closedFirst = first.closeFocusedGroup()
        #expect(closedFirst)
        #expect(titles(first) == [["shell", "agent"]])
        #expect(first.focusedPane?.id == "agent")
    }
}

struct PaneFocusTests {
    @Test func focusMovesBetweenPanesAndTabsCycleWithinOne() {
        var layout = agentAndWork(["a", "b", "c"])
        layout.focus(.right)
        #expect(layout.focusedPane?.id == "a")
        layout.cycleTab(by: 1)
        #expect(layout.focusedPane?.id == "b")
        layout.cycleTab(by: -2)
        #expect(layout.focusedPane?.id == "c")
        layout.selectTab(0)
        #expect(layout.focusedPane?.id == "a")
        layout.focus(.left)
        #expect(layout.focusedPane?.id == "agent")
        // Each pane keeps its own active tab.
        #expect(layout.groups[1].active?.title == "a")
        layout.focus(.left)
        #expect(layout.focusedPane?.id == "agent")
    }

    @Test func aSplitMakesANewFocusedPaneBesideTheFocusedOne() {
        var layout = agentAndWork(["shell"])
        layout.focus(pane: "shell")
        layout.split(.vertical, with: tab("below"))
        #expect(titles(layout) == [["agent"], ["shell"], ["below"]])
        #expect(layout.focusedPane?.id == "below")
        layout.focus(.up)
        #expect(layout.focusedPane?.id == "shell")
    }

    @Test func promptsGoToTheFirstAgent() {
        #expect(TaskLayout(tabs: [tab("s"), tab("a", .agent)]).agentPane == "a")
        #expect(TaskLayout(tabs: [tab("s")]).agentPane == "s")
        #expect(TaskLayout().agentPane == nil)
    }

    @Test func aLayoutSurvivesTheCache() throws {
        var layout = agentAndWork(["shell", "jest"])
        layout.focus(pane: "jest")
        layout.zoomed = true
        layout.closedAgent = ClosedAgent(claudeSessionID: "s", directory: "/w")
        let decoded = try JSONDecoder().decode(TaskLayout.self, from: JSONEncoder().encode(layout))
        #expect(decoded == layout)
    }
}

struct LegacyLayoutTests {
    /// The shape Heed cached before panes had tabs: tabs of split panes.
    private let legacy = #"""
    {"activeTab": 1, "tabs": [
      {"id": "T1", "title": "agent", "focused": "agent", "zoomed": false,
       "tree": {"split": {"_0": "horizontal",
         "_1": {"leaf": {"_0": {"id": "agent", "role": "agent", "title": "claude", "directory": "/w",
                                "command": "claude --session-id s-1"}}},
         "_2": {"leaf": {"_0": {"id": "shell", "role": "shell", "title": "zsh", "directory": "/w"}}},
         "ratio": 0.6}}},
      {"id": "T2", "title": "localhost", "focused": "page", "zoomed": false,
       "tree": {"leaf": {"_0": {"id": "page", "role": "browser", "title": "Kibana", "directory": "/w",
                                "url": "http://localhost:5601/app/home"}}}},
      {"id": "T3", "title": "kibana", "focused": "kbn", "zoomed": false,
       "tree": {"leaf": {"_0": {"id": "kbn", "role": "shell", "title": "yarn start", "directory": "/w",
                                "command": "pk kbn"}}}}
    ], "closedAgent": {"claudeSessionID": "s-0", "directory": "/old"}}
    """#

    @Test func everyPaneBecomesATabWithTheAgentOnTheLeft() throws {
        let layout = try JSONDecoder().decode(TaskLayout.self, from: Data(legacy.utf8))
        #expect(titles(layout) == [["agent"], ["zsh", "localhost", "kibana"]])
        // Pane ids stay: the hooks and the terminals' sessions know them.
        #expect(layout.panes.map(\.id) == ["agent", "shell", "page", "kbn"])
        #expect(layout.pane("agent")?.command == "claude --session-id s-1")
        #expect(layout.pane("page")?.url == "http://localhost:5601/app/home")
        // The tab that was active keeps the keys.
        #expect(layout.focusedPane?.id == "page")
        #expect(layout.closedAgent == ClosedAgent(claudeSessionID: "s-0", directory: "/old"))
        // Written back, it is the new shape.
        let again = try JSONDecoder().decode(TaskLayout.self, from: JSONEncoder().encode(layout))
        #expect(again == layout)
    }

    @Test func withoutAnAgentItIsOnePane() throws {
        let json = #"""
        {"activeTab": 0, "tabs": [{"id": "T1", "title": "shell", "focused": "s", "zoomed": false,
          "tree": {"leaf": {"_0": {"id": "s", "role": "shell", "title": "zsh", "directory": "/w"}}}}]}
        """#
        let layout = try JSONDecoder().decode(TaskLayout.self, from: Data(json.utf8))
        #expect(titles(layout) == [["shell"]])
        #expect(layout.tabs.first?.id == "T1")
    }

    /// `HEED_LAYOUT_SAMPLE=<copy of domain.json>`: a real cache converts without losing a pane.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEED_LAYOUT_SAMPLE"] != nil))
    func aRealCacheConverts() throws {
        let path = try #require(ProcessInfo.processInfo.environment["HEED_LAYOUT_SAMPLE"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rawLayouts = try #require((raw["domain"] as? [String: Any])?["layouts"] as? [String: Any])
        let domain = try DomainStore.decode(data).get()
        #expect(domain.layouts.count == rawLayouts.count)
        for (task, value) in rawLayouts {
            let old = try #require(String(data: JSONSerialization.data(withJSONObject: value), encoding: .utf8))
            let layout = try #require(domain.layouts[task])
            #expect(layout.panes.count == old.components(separatedBy: "\"role\"").count - 1)
            #expect(Set(layout.panes.map(\.id)).count == layout.panes.count)
            #expect(layout.focusedPane != nil || layout.isEmpty)
            #expect(layout.groups.filter(\.hasAgent).count <= 1)
        }
    }
}
