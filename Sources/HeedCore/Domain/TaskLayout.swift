import Foundation

/// A task's panes and their tabs: restored on launch, so it is part of the domain rather than view state.
///
/// Where a new tab goes: an agent tab in the agent's pane (the first pane with an agent in it, else a new pane on the
/// left); any other tab in the work pane (the focused pane when it has no agent, else the first pane without one), and
/// when every pane has an agent, in a new pane to the right of the agent's. So the agent stays in view.
public struct TaskLayout: Hashable, Sendable {
    /// Nil when the task has no tab at all.
    public var root: PaneTree?
    /// The pane keys go to.
    public var focusedGroup: String?
    /// The focused pane fills the task's area.
    public var zoomed: Bool
    /// The agent whose tab closed last, so `tab.agent` can resume it.
    public var closedAgent: ClosedAgent?

    public init(root: PaneTree?, focusedGroup: String? = nil, zoomed: Bool = false, closedAgent: ClosedAgent? = nil) {
        self.root = root
        self.focusedGroup = focusedGroup ?? root?.groups.first?.id
        self.zoomed = zoomed
        self.closedAgent = closedAgent
    }

    /// One pane with `tabs` (none: no pane at all).
    public init(tabs: [PaneTab] = [], activeTab: Int = 0, closedAgent: ClosedAgent? = nil) {
        self.init(
            root: tabs.isEmpty ? nil : .leaf(PaneGroup(tabs: tabs, activeTab: activeTab)), closedAgent: closedAgent
        )
    }

    // MARK: Reading

    /// Panes in reading order.
    public var groups: [PaneGroup] { root?.groups ?? [] }
    /// Every tab, pane by pane.
    public var tabs: [PaneTab] { groups.flatMap(\.tabs) }
    /// What every tab shows, pane by pane.
    public var panes: [PaneSpec] { tabs.map(\.pane) }
    public var isEmpty: Bool { root == nil }

    public func group(_ id: String) -> PaneGroup? { groups.first { $0.id == id } }
    /// The focused pane (the first when none is recorded).
    public var focused: PaneGroup? { focusedGroup.flatMap { group($0) } ?? groups.first }
    /// What the focused pane's active tab shows: where keys go.
    public var focusedPane: PaneSpec? { focused?.active?.pane }

    public func contains(pane id: String) -> Bool { groups.contains { $0.index(ofPane: id) != nil } }
    public func group(ofPane id: String) -> PaneGroup? { groups.first { $0.index(ofPane: id) != nil } }
    public func pane(_ id: String) -> PaneSpec? { panes.first { $0.id == id } }

    /// The first agent, else the first tab: where prompts are typed.
    public var agentPane: String? { (panes.first { $0.role == .agent } ?? panes.first)?.id }

    // MARK: Opening tabs

    /// Adds `tab` where the rules put it (or into pane `groupID`), right after the tab showing `nextTo` when that is
    /// in the same pane, else at the end. `show` makes it its pane's active tab and, unless `focus` is false, focuses
    /// that pane; otherwise the focused pane and every active tab stay. Returns the pane it went into.
    @discardableResult
    public mutating func add(
        _ tab: PaneTab, show: Bool, focus: Bool = true, nextTo: String? = nil, in groupID: String? = nil
    ) -> String {
        guard let root else {
            let group = PaneGroup(tabs: [tab])
            self = TaskLayout(root: .leaf(group), zoomed: false, closedAgent: closedAgent)
            return group.id
        }
        let isAgent = tab.pane.role == .agent
        let target = groupID.flatMap { group($0) }?.id ?? (isAgent ? groups.first(where: \.hasAgent)?.id : workGroup)
        guard let target else {
            let group = PaneGroup(tabs: [tab])
            if isAgent {
                self.root = .split(.horizontal, .leaf(group), root, ratio: 0.5)
            } else {
                let beside = groups.first(where: \.hasAgent)?.id ?? groups[0].id
                self.root = root.splitting(beside, axis: .horizontal, with: group)
            }
            if show, focus {
                focusedGroup = group.id
                zoomed = false
            }
            return group.id
        }
        self.root = root.updatingGroup(target) { group in
            let index = nextTo.flatMap(group.index(ofPane:)).map { $0 + 1 } ?? group.tabs.count
            group.tabs.insert(tab, at: index)
            if show {
                group.activeTab = index
            } else if group.tabs.count > 1, group.activeTab >= index {
                group.activeTab += 1
            }
        }
        if show, focus { focusedGroup = target }
        return target
    }

    /// The pane other tabs open in; nil when every pane has an agent (a new pane opens).
    var workGroup: String? {
        if let focused, !focused.hasAgent { return focused.id }
        return groups.first { !$0.hasAgent }?.id
    }

    /// A tab with a page at `url`, next to the tab showing `nextTo` when that is in the work pane. Returns the page.
    @discardableResult
    public mutating func openPage(_ url: String?, nextTo: String? = nil, directory: String, show: Bool) -> PaneSpec {
        let pane = PaneSpec(role: .browser, title: "", directory: directory, url: url)
        add(PaneTab(title: BrowserAddress.tabTitle(title: "", url: url), pane: pane), show: show, nextTo: nextTo)
        return pane
    }

    /// `⌃w v` / `⌃w s`: a new pane beside the focused one with `tab` in it, focused.
    public mutating func split(_ axis: PaneTree.Axis, with tab: PaneTab) {
        guard let root, let focused else {
            add(tab, show: true)
            return
        }
        let group = PaneGroup(tabs: [tab])
        self.root = root.splitting(focused.id, axis: axis, with: group)
        focusedGroup = group.id
        zoomed = false
    }

    // MARK: Focus

    /// Shows the tab with `pane` in it and focuses its pane.
    public mutating func focus(pane id: String) {
        guard let root, let group = group(ofPane: id), let index = group.index(ofPane: id) else { return }
        self.root = root.updatingGroup(group.id) { $0.activeTab = index }
        focusedGroup = group.id
    }

    /// Focuses the pane on that side of the focused one, if any.
    public mutating func focus(_ direction: PaneTree.Direction) {
        guard let root, let focused, let next = root.neighbor(of: focused.id, direction) else { return }
        focusedGroup = next
    }

    /// The focused pane's tab `index`.
    public mutating func selectTab(_ index: Int) {
        guard let root, let focused, focused.tabs.indices.contains(index) else { return }
        self.root = root.updatingGroup(focused.id) { $0.activeTab = index }
    }

    /// The focused pane's next (`delta` > 0) or previous tab, round.
    public mutating func cycleTab(by delta: Int) {
        guard let focused, !focused.tabs.isEmpty else { return }
        let count = focused.tabs.count
        selectTab(((focused.activeTab + delta) % count + count) % count)
    }

    // MARK: Closing and moving

    /// Removes the tab showing pane `id`; a pane left without tabs goes too. False when no tab shows it.
    @discardableResult
    public mutating func removePane(_ id: String) -> Bool {
        guard let group = group(ofPane: id), let index = group.index(ofPane: id) else { return false }
        removeTab(at: index, in: group.id)
        return true
    }

    /// Removes a pane's tab `index`; a pane left without tabs goes too.
    public mutating func removeTab(at index: Int, in groupID: String) {
        guard let root, let group = group(groupID), group.tabs.indices.contains(index) else { return }
        if group.tabs.count == 1 { return removeGroup(groupID) }
        self.root = root.updatingGroup(groupID) { $0.removeTab(at: index) }
    }

    /// `⌃w q`: closes the focused pane; its tabs join the pane before it in reading order (or after, for the first),
    /// so nothing stops. False when it is the only pane.
    @discardableResult
    public mutating func closeFocusedGroup() -> Bool {
        guard let root, let focused, groups.count > 1,
              let position = groups.firstIndex(where: { $0.id == focused.id })
        else { return false }
        let into = groups[position == 0 ? 1 : position - 1].id
        self.root = root.removing(focused.id)?.updatingGroup(into) { group in
            group.tabs += focused.tabs
            group.activeTab = group.tabs.count - focused.tabs.count + focused.activeTab
        }
        focusedGroup = into
        zoomed = false
        return true
    }

    /// Moves tab `id` to position `index` of pane `groupID` (dragged in or onto a tab strip). Within its pane the
    /// active tab stays the same tab; moved to another pane it becomes that pane's active tab, focused. The pane it
    /// left goes when empty.
    public mutating func moveTab(_ id: String, to index: Int, in groupID: String? = nil) {
        guard let root, let source = groups.first(where: { $0.tabs.contains { $0.id == id } }),
              let from = source.tabs.firstIndex(where: { $0.id == id })
        else { return }
        let targetID = groupID.flatMap { group($0) }?.id ?? source.id
        let tab = source.tabs[from]
        if targetID == source.id {
            self.root = root.updatingGroup(source.id) { group in
                let active = group.active?.id
                group.tabs.remove(at: from)
                group.tabs.insert(tab, at: min(max(index, 0), group.tabs.count))
                if let active, let now = group.tabs.firstIndex(where: { $0.id == active }) { group.activeTab = now }
            }
            return
        }
        self.root = root.updatingGroup(targetID) { group in
            let at = min(max(index, 0), group.tabs.count)
            group.tabs.insert(tab, at: at)
            group.activeTab = at
        }
        if source.tabs.count == 1 {
            removeGroup(source.id)
        } else {
            self.root = self.root?.updatingGroup(source.id) { $0.removeTab(at: from) }
        }
        focusedGroup = targetID
    }

    private mutating func removeGroup(_ id: String) {
        let order = groups.map(\.id)
        root = root?.removing(id)
        if focusedGroup == id || root == nil {
            let position = order.firstIndex(of: id) ?? 0
            let left = groups.map(\.id)
            focusedGroup = left.isEmpty ? nil : left[min(max(position - 1, 0), left.count - 1)]
            zoomed = false
        }
    }

    // MARK: Pages and sizes

    /// A page went somewhere or got its title: its tab keeps both and is named after it.
    public mutating func pageChanged(_ id: String, url: String, title: String) {
        guard let root, let group = group(ofPane: id), let index = group.index(ofPane: id) else { return }
        self.root = root.updatingGroup(group.id) { group in
            group.tabs[index].pane.url = url
            group.tabs[index].pane.title = title
            group.tabs[index].title = BrowserAddress.tabTitle(title: title, url: url)
        }
    }

    /// What tab `id` shows, edited.
    public mutating func update(pane id: String, _ edit: (inout PaneSpec) -> Void) {
        root = root?.updating(id, edit)
    }

    /// A divider let go: see `PaneTree.settingRatio`.
    public mutating func setRatio(_ ratio: Double, at path: [Int]) {
        root = root?.settingRatio(ratio, at: path)
    }
}

/// An agent tab that was closed: its Claude session and the folder it last worked in.
public struct ClosedAgent: Hashable, Sendable, Codable {
    public var claudeSessionID: String
    public var directory: String

    public init(claudeSessionID: String, directory: String) {
        self.claudeSessionID = claudeSessionID
        self.directory = directory
    }
}

// MARK: Cache

extension TaskLayout: Codable {
    private enum CodingKeys: String, CodingKey { case root, focusedGroup, zoomed, closedAgent }
    /// Before panes had their own tabs: a list of tabs, each a split tree of panes.
    private enum LegacyKeys: String, CodingKey { case tabs, activeTab }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let closedAgent = try container.decodeIfPresent(ClosedAgent.self, forKey: .closedAgent)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if !container.contains(.root), legacy.contains(.tabs) {
            self = try Self.converting(
                legacy.decode([LegacyTab].self, forKey: .tabs),
                activeTab: legacy.decodeIfPresent(Int.self, forKey: .activeTab) ?? 0,
                closedAgent: closedAgent
            )
            return
        }
        try self.init(
            root: container.decodeIfPresent(PaneTree.self, forKey: .root),
            focusedGroup: container.decodeIfPresent(String.self, forKey: .focusedGroup),
            zoomed: container.decodeIfPresent(Bool.self, forKey: .zoomed) ?? false,
            closedAgent: closedAgent
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(root, forKey: .root)
        try container.encodeIfPresent(focusedGroup, forKey: .focusedGroup)
        try container.encode(zoomed, forKey: .zoomed)
        try container.encodeIfPresent(closedAgent, forKey: .closedAgent)
    }

    /// An old layout: every pane of every tab becomes a tab, keeping its id (the hooks' pane id), command and page.
    /// The agents go in a pane on the left and the rest in one on its right; without both, one pane. The pane that
    /// had the keys keeps them.
    static func converting(_ old: [LegacyTab], activeTab: Int, closedAgent: ClosedAgent?) -> TaskLayout {
        var tabs: [PaneTab] = []
        for tab in old {
            let panes = tab.tree.panes
            for pane in panes {
                let alone = panes.count == 1
                let title = alone ? tab.title : pane.role == .agent ? "agent" : pane.title
                tabs.append(PaneTab(
                    id: pane.id == panes.first?.id ? tab.id : "\(tab.id)-\(pane.id)",
                    title: title,
                    pane: pane
                ))
            }
        }
        let focus = old.indices.contains(activeTab) ? old[activeTab].focused : nil
        let agents = tabs.filter { $0.pane.role == .agent }
        let others = tabs.filter { $0.pane.role != .agent }
        func group(_ id: String, _ tabs: [PaneTab]) -> PaneGroup {
            PaneGroup(id: id, tabs: tabs, activeTab: tabs.firstIndex { $0.pane.id == focus } ?? 0)
        }
        let root: PaneTree? = if tabs.isEmpty {
            nil
        } else if agents.isEmpty || others.isEmpty {
            .leaf(group("pane-1", tabs))
        } else {
            .split(.horizontal, .leaf(group("pane-1", agents)), .leaf(group("pane-2", others)), ratio: 0.5)
        }
        var layout = TaskLayout(root: root, closedAgent: closedAgent)
        if let focus, let owner = layout.group(ofPane: focus) { layout.focusedGroup = owner.id }
        return layout
    }

    struct LegacyTab: Decodable {
        let id: String
        let title: String
        let tree: LegacyTree
        let focused: String?
    }

    indirect enum LegacyTree: Decodable {
        case leaf(PaneSpec)
        case split(PaneTree.Axis, LegacyTree, LegacyTree, ratio: Double)

        var panes: [PaneSpec] {
            switch self {
            case let .leaf(pane): [pane]
            case let .split(_, first, second, _): first.panes + second.panes
            }
        }
    }
}
