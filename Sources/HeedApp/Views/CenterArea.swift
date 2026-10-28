import HeedCore
import SwiftUI
import UniformTypeIdentifiers

/// The current task's panes, each with its tab strip and its active tab.
struct CenterArea: View {
    @Environment(AppModel.self) private var model
    /// The tab being dragged, within a strip or onto another pane's.
    @State private var draggedTab: String?

    var body: some View {
        Group {
            if let layout = model.currentLayout, let root = layout.root {
                let topRight = root.topRight.id
                Group {
                    if layout.zoomed, let group = layout.focused {
                        GroupView(group: group, topRight: true, focused: true, draggedTab: $draggedTab)
                    } else {
                        PaneTreeView(
                            tree: root, path: [], topRight: topRight, focused: layout.focused?.id,
                            draggedTab: $draggedTab
                        )
                    }
                }
                .shotRegion(.panes)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Spacer()
                        StripHints(keys: true)
                    }
                    .frame(height: 36)
                    .background(Theme.bg2)
                    .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                    .shotRegion(.tabStrip)
                    EmptyCenter()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.pane)
    }
}

/// The panes as the layout splits them, with a draggable divider between the two sides of each split.
private struct PaneTreeView: View {
    @Environment(AppModel.self) private var model
    let tree: PaneTree
    /// Where this part sits in the tree (0 a split's first side, 1 its second): how a divider names its split.
    let path: [Int]
    let topRight: String
    let focused: String?
    @Binding var draggedTab: String?
    /// The ratio while the divider is dragged; the layout gets it when the mouse is let go.
    @State private var dragging: Double?

    var body: some View {
        switch tree {
        case let .leaf(group):
            GroupView(
                group: group, topRight: group.id == topRight, focused: group.id == focused, draggedTab: $draggedTab
            )
        case let .split(axis, first, second, ratio):
            GeometryReader { geometry in
                let sideways = axis == .horizontal
                let length = max((sideways ? geometry.size.width : geometry.size.height) - 1, 1)
                let shown = dragging ?? ratio
                let dragged = { (distance: CGFloat) in
                    min(max(ratio + distance / length, PaneTree.ratios.lowerBound), PaneTree.ratios.upperBound)
                }
                Group {
                    if sideways {
                        HStack(spacing: 1) {
                            side(first, 0).frame(width: length * shown)
                            side(second, 1)
                        }
                    } else {
                        VStack(spacing: 1) {
                            side(first, 0).frame(height: length * shown)
                            side(second, 1)
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    ResizeHandle(
                        axis: sideways ? .horizontal : .vertical,
                        moved: { dragging = dragged($0) },
                        ended: {
                            model.setSplitRatio(dragged($0), at: path)
                            dragging = nil
                        }
                    )
                    .frame(width: sideways ? 7 : nil, height: sideways ? nil : 7)
                    .offset(x: sideways ? length * shown - 3 : 0, y: sideways ? 0 : length * shown - 3)
                }
            }
            .background(Theme.line)
        }
    }

    private func side(_ tree: PaneTree, _ step: Int) -> PaneTreeView {
        PaneTreeView(tree: tree, path: path + [step], topRight: topRight, focused: focused, draggedTab: $draggedTab)
    }
}

/// One pane: its tab strip over its active tab.
private struct GroupView: View {
    let group: PaneGroup
    /// The top right pane's strip also holds the key hints and the inspector button.
    let topRight: Bool
    let focused: Bool
    @Binding var draggedTab: String?

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(group: group, topRight: topRight, focused: focused, draggedTab: $draggedTab)
                .shotRegion(topRight ? ShotRegion.tabStrip : nil)
            if let tab = group.active {
                // A terminal must survive re-layout (splits, zoom, a tab moved); identity is the pane id.
                PaneView(pane: tab.pane, active: focused).id(tab.pane.id)
            } else {
                Theme.pane
            }
        }
    }
}

private struct TabStrip: View {
    @Environment(AppModel.self) private var model
    let group: PaneGroup
    let topRight: Bool
    let focused: Bool
    @Binding var draggedTab: String?
    @State private var width: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            // More tabs than fit scroll sideways rather than push the hints off; the active one stays in view.
            if ShotMode.active {
                // Docs shots render offscreen, where a scroll view's content isn't drawn.
                tabs.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) { tabs }
                        .onAppear { reveal(proxy) }
                        .onChange(of: group.active?.id) { reveal(proxy) }
                }
            }
            // A narrow pane keeps its strip for tabs; the status bar has the keys too.
            if topRight { StripHints(keys: width >= 560) }
        }
        .frame(height: 36)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Theme.bg2)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { model.focusGroup(group.id) }
        // A tab dropped past the last one goes to the end of this pane.
        .unlessShot {
            $0.onDrop(
                of: [.text],
                delegate: TabDrop(
                    group: group.id, index: group.tabs.count, target: nil, dragged: $draggedTab, model: model
                )
            )
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        if let id = group.active?.id { proxy.scrollTo(id) }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Array(group.tabs.enumerated()), id: \.element.id) { index, tab in
                let on = index == group.activeTab
                HStack(spacing: 8) {
                    glyph(tab.pane)
                    Text(tab.title).lineLimit(1).fixedSize()
                    TabCloseButton { model.closeTab(tab.id) }
                }
                .font(Theme.mono(12))
                .foregroundStyle(on && focused ? Theme.fg : on ? Theme.fg2 : Theme.fg3)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(on ? Theme.pane : .clear)
                .overlay(alignment: .bottom) {
                    if on { (focused ? Theme.inverse : Theme.line).frame(height: 2) }
                }
                .contentShape(Rectangle())
                .onTapGesture { model.selectTab(tab.id) }
                // Dragged along a strip, a tab takes the place of the one it passes over, in this pane or another.
                .unlessShot {
                    $0.onDrag {
                        draggedTab = tab.id
                        return NSItemProvider(object: tab.id as NSString)
                    }
                    .onDrop(
                        of: [.text],
                        delegate: TabDrop(
                            group: group.id, index: index, target: tab.id, dragged: $draggedTab, model: model
                        )
                    )
                }
                .id(tab.id)
            }
            Text("+").font(Theme.mono(13)).foregroundStyle(Theme.fg3).padding(.horizontal, 14)
                .frame(height: 36)
                .contentShape(Rectangle())
                .onTapGesture { model.newTab(in: group.id) }
                .help("New tab with a shell, in this pane (:tab.new)")
        }
    }

    /// The agent's state, a pinned command's last run, or a globe for a page.
    @ViewBuilder private func glyph(_ pane: PaneSpec) -> some View {
        switch pane.role {
        case .agent:
            let state = (model.agents[pane.id] ?? AgentTab()).state
            StateGlyph(state: state.state, guessed: state.source == .guessed, size: 11)
        case .command:
            if let code = model.commandResults[pane.id] {
                // Done when it passed, a red square when it failed.
                if code == 0 {
                    StateGlyph(state: .done, size: 11)
                } else {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.err).frame(width: 9, height: 9)
                }
            }
        case .browser:
            Image(systemName: "globe").font(.system(size: 10))
        case .diff:
            Image(systemName: "plusminus").font(.system(size: 10, weight: .semibold))
        case .shell:
            EmptyView()
        }
    }
}

/// What the keys do here, as you have them bound (unless `keys` is false), and the inspector button when it is
/// hidden.
private struct StripHints: View {
    @Environment(AppModel.self) private var model
    let keys: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Into the terminal in NORMAL, back out in INSERT.
            if !keys {
                EmptyView()
            } else if model.mode == .insert {
                HStack(spacing: 5) {
                    KeyCap(text: "⇧ esc")
                    let chord = KeyCapText.of(model.config.insertEscape)
                    if chord != "⇧⎋" {
                        Text("or").foregroundStyle(Theme.fg3)
                        KeyCap(text: chord)
                    }
                    Text("normal").foregroundStyle(Theme.fg3)
                }
                .fixedSize()
                hint(model.keyLabel(for: "pane.split.right"), "split right")
            } else {
                hint(model.keyLabel(for: "mode.insert"), "insert")
                hint(model.keyLabel(for: "pane.split.right"), "split right")
                hint(model.keyLabel(for: "tab.next"), "tab")
            }
            if !model.inspectorVisible {
                CollapseButton(systemImage: "sidebar.right", key: "zi") { model.toggleInspector() }
            }
        }
        .font(Theme.ui(11.5))
        .padding(.horizontal, 14)
    }

    /// A key and what it does; nothing when the command has no key.
    @ViewBuilder private func hint(_ key: String?, _ label: String) -> some View {
        if let key {
            HStack(spacing: 5) {
                KeyCap(text: key)
                Text(label).foregroundStyle(Theme.fg3)
            }
            .fixedSize()
        }
    }
}

extension View {
    /// Drag and drop, left out of docs shots: they render offscreen, where it draws as a placeholder.
    @ViewBuilder func unlessShot(_ apply: (Self) -> some View) -> some View {
        if ShotMode.active { self } else { apply(self) }
    }
}

/// A tab dragged over another one moves into its place (or, over a strip's empty end, to the end of that pane), so
/// the strips show the new order while you drag.
private struct TabDrop: DropDelegate {
    let group: String
    let index: Int
    /// The tab under the pointer; nil for the strip itself.
    let target: String?
    @Binding var dragged: String?
    let model: AppModel

    func dropEntered(info _: DropInfo) {
        guard let dragged, dragged != target else { return }
        let source = model.currentLayout?.groups.first { $0.tabs.contains { $0.id == dragged } }
        // The strip's end only takes a tab from another pane; within its own, the tabs it passes over place it.
        if target == nil, source?.id == group { return }
        model.moveTab(dragged, to: index, in: group)
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info _: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}

/// A tab's ×: closes the tab (asking first when the agent is in it).
private struct TabCloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(hovering ? Theme.fg : Theme.fg3)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.bg3 : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help("Close tab (:tab.close)")
    }
}

/// What a pane's active tab shows: a terminal, or a page under its address bar.
private struct PaneView: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    /// Its pane is the focused one.
    let active: Bool

    var body: some View {
        VStack(spacing: 0) {
            if pane.role == .browser {
                HStack(spacing: 8) { BrowserToolbar(pane: pane) }
                    .font(Theme.mono(11))
                    .foregroundStyle(active ? Theme.fg : Theme.fg3)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Theme.paneHeader)
            }
            if pane.role == .diff {
                DiffTabView(pane: pane, active: active)
            } else if ShotMode.active {
                if pane.role == .browser { FakeBrowser(pane: pane) } else { FakeTerminal(pane: pane) }
            } else if pane.role == .browser, model.isFixture {
                // Pages in fixtures and snapshots stay off the network.
                FakeBrowser(pane: pane)
            } else if pane.role == .browser {
                BrowserPane(
                    pane: pane, isFocused: active && model.mode == .insert, focusRequest: model.terminalFocusRequest
                )
                .overlay {
                    if let failure = BrowserSurfaces.shared.page(for: pane).failure { PageFailure(message: failure) }
                }
            } else if !model.terminalsReady {
                // The PATH and zmx sessions are not known yet; a terminal made now would start with the wrong ones.
                Theme.pane
            } else {
                TerminalPane(
                    pane: pane,
                    sessionID: model.currentTask?.id ?? "",
                    isFocused: active && model.mode == .insert,
                    focusRequest: model.terminalFocusRequest
                )
            }
        }
        .background(Theme.pane)
        // White only on the pane your keys go to (INSERT); in NORMAL no pane takes input, so the focused one is quiet.
        .overlay {
            if active, model.mode == .insert {
                Rectangle().strokeBorder(Color.white, lineWidth: 1.5)
            } else if active {
                Rectangle().strokeBorder(Theme.paneActive.opacity(0.3), lineWidth: 1)
            }
        }
        .overlay(alignment: .topLeading) {
            if let hint = model.hintLabel(for: .pane(pane.id)) { HintBadge(label: hint).padding(30) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // A page reports clicks into it itself; its address bar holds the address field, which must keep the click.
            // The diff is read only: a click on it gives it the keys in NORMAL.
            switch pane.role {
            case .browser: model.focusPane(pane.id)
            case .diff: model.clickedDiff(pane.id)
            default: model.clickedPane(pane.id)
            }
        }
    }
}

private struct EmptyCenter: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("No task").font(Theme.ui(15, weight: .medium))
            HStack(spacing: 6) {
                KeyCap(text: "o")
                Text("new task").foregroundStyle(Theme.fg3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
