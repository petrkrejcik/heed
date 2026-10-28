import Foundation

/// What a tab shows: a terminal (an agent, a shell, a command) or a web page. The terminal itself lives in the app;
/// this is the record that survives a relaunch. Its id is the pane id the hooks report (`HEED_PANE_ID`).
public struct PaneSpec: Hashable, Sendable, Codable, Identifiable {
    public enum Role: String, Sendable, Codable {
        /// The shell the agent runs in; the tab survives the agent exiting.
        case agent
        case shell
        /// A pinned command (`[commands]`: test, build); its exit code sets the tab's glyph.
        case command
        /// A web page (`url`), not a terminal: `title` is the page's.
        case browser
        /// The task's changes (`directory` is the checkout), not a terminal: read only, keys stay Heed's.
        case diff

        /// A tab that shows a terminal and takes keys in INSERT.
        public var isTerminal: Bool {
            switch self {
            case .agent, .shell, .command: true
            case .browser, .diff: false
            }
        }

        /// A role this build no longer has (a cached `helper` pane) comes back as a shell.
        public init(from decoder: Decoder) throws {
            self = try Role(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .shell
        }
    }

    public var id: String
    public var role: Role
    public var title: String
    public var directory: String
    /// Typed into the shell once it starts (the agent command, a pinned command). Nil for a plain shell.
    public var command: String?
    /// The address a page shows, as last navigated; nil for terminals and for a page not given one yet.
    public var url: String?

    public init(
        id: String = UUID().uuidString, role: Role, title: String, directory: String, command: String? = nil,
        url: String? = nil
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.directory = directory
        self.command = command
        self.url = url
    }
}

/// A tab in a pane: a name and the one thing it shows.
public struct PaneTab: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var pane: PaneSpec

    public init(id: String = UUID().uuidString, title: String, pane: PaneSpec) {
        self.id = id
        self.title = title
        self.pane = pane
    }
}

/// A pane of a task's layout: a region with its own tab strip, showing its active tab. In the UI this is "a pane".
public struct PaneGroup: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var tabs: [PaneTab]
    public var activeTab: Int

    public init(id: String = UUID().uuidString, tabs: [PaneTab], activeTab: Int = 0) {
        self.id = id
        self.tabs = tabs
        self.activeTab = activeTab
    }

    public var active: PaneTab? { tabs.indices.contains(activeTab) ? tabs[activeTab] : nil }
    public var hasAgent: Bool { tabs.contains { $0.pane.role == .agent } }
    public func index(ofPane id: String) -> Int? { tabs.firstIndex { $0.pane.id == id } }

    /// Removes a tab, keeping the active one active (or its neighbour, when it was the one removed).
    mutating func removeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        if index < activeTab { activeTab -= 1 }
        activeTab = max(0, min(activeTab, tabs.count - 1))
    }
}

/// A task's panes as a binary split tree, vim-style: `<C-w>v` puts a new pane to the right, `<C-w>s` below.
public indirect enum PaneTree: Hashable, Sendable, Codable {
    public enum Axis: String, Sendable, Codable {
        /// Side by side.
        case horizontal
        /// Stacked.
        case vertical
    }

    case leaf(PaneGroup)
    case split(Axis, PaneTree, PaneTree, ratio: Double)

    /// Panes in reading order (left to right, top to bottom); their 1-based position is the pane number in the UI.
    public var groups: [PaneGroup] {
        switch self {
        case let .leaf(group): [group]
        case let .split(_, first, second, _): first.groups + second.groups
        }
    }

    public func contains(group id: String) -> Bool { groups.contains { $0.id == id } }

    /// The pane in the top right corner: its tab strip also holds the key hints and the inspector button.
    public var topRight: PaneGroup {
        switch self {
        case let .leaf(group): group
        case let .split(axis, first, second, _): axis == .horizontal ? second.topRight : first.topRight
        }
    }

    /// The same tree with pane `id` edited.
    public func updatingGroup(_ id: String, _ edit: (inout PaneGroup) -> Void) -> PaneTree {
        switch self {
        case var .leaf(group):
            guard group.id == id else { return self }
            edit(&group)
            return .leaf(group)
        case let .split(axis, first, second, ratio):
            return .split(axis, first.updatingGroup(id, edit), second.updatingGroup(id, edit), ratio: ratio)
        }
    }

    /// The same tree with what tab `id` shows edited, wherever it is.
    public func updating(_ id: String, _ edit: (inout PaneSpec) -> Void) -> PaneTree {
        switch self {
        case var .leaf(group):
            guard let index = group.index(ofPane: id) else { return self }
            edit(&group.tabs[index].pane)
            return .leaf(group)
        case let .split(axis, first, second, ratio):
            return .split(axis, first.updating(id, edit), second.updating(id, edit), ratio: ratio)
        }
    }

    /// Splits pane `id`, putting `new` to its right (horizontal) or below it (vertical).
    public func splitting(_ id: String, axis: Axis, with new: PaneGroup) -> PaneTree {
        switch self {
        case let .leaf(group) where group.id == id:
            .split(axis, self, .leaf(new), ratio: 0.5)
        case .leaf:
            self
        case let .split(splitAxis, first, second, ratio):
            .split(
                splitAxis, first.splitting(id, axis: axis, with: new), second.splitting(id, axis: axis, with: new),
                ratio: ratio
            )
        }
    }

    /// Removes pane `id`; its sibling takes the space. Nil when it was the last pane.
    public func removing(_ id: String) -> PaneTree? {
        switch self {
        case let .leaf(group):
            return group.id == id ? nil : self
        case let .split(axis, first, second, ratio):
            guard contains(group: id) else { return self }
            switch (first.removing(id), second.removing(id)) {
            case let (lhs?, rhs?): return .split(axis, lhs, rhs, ratio: ratio)
            case let (lhs?, nil): return lhs
            case let (nil, rhs?): return rhs
            case (nil, nil): return nil
            }
        }
    }

    /// How far a split's divider can be dragged: each side keeps a tenth of the space.
    public static let ratios: ClosedRange<Double> = 0.1 ... 0.9

    /// The same tree with the split at `path` (0 is a split's first side, 1 its second, from the root) at `ratio`,
    /// kept within `ratios`. Unchanged when `path` leads to no split.
    public func settingRatio(_ ratio: Double, at path: [Int]) -> PaneTree {
        guard case let .split(axis, first, second, current) = self else { return self }
        guard let step = path.first else {
            return .split(axis, first, second, ratio: min(max(ratio, Self.ratios.lowerBound), Self.ratios.upperBound))
        }
        let rest = Array(path.dropFirst())
        return switch step {
        case 0: .split(axis, first.settingRatio(ratio, at: rest), second, ratio: current)
        case 1: .split(axis, first, second.settingRatio(ratio, at: rest), ratio: current)
        default: self
        }
    }

    public enum Direction: Sendable { case left, right, up, down }

    /// The pane focus moves to from pane `id` in `direction`: the nearest pane on that side of the enclosing split.
    public func neighbor(of id: String, _ direction: Direction) -> String? {
        let axis: Axis = (direction == .left || direction == .right) ? .horizontal : .vertical
        let forward = direction == .right || direction == .down
        return neighbor(of: id, axis: axis, forward: forward)
    }

    private func neighbor(of id: String, axis: Axis, forward: Bool) -> String? {
        guard case let .split(splitAxis, first, second, _) = self else { return nil }
        let inFirst = first.contains(group: id)
        let inner = inFirst ? first : second
        if let found = inner.neighbor(of: id, axis: axis, forward: forward) { return found }
        guard splitAxis == axis else { return nil }
        if inFirst, forward { return second.groups.first?.id }
        if !inFirst, !forward { return first.groups.last?.id }
        return nil
    }
}
