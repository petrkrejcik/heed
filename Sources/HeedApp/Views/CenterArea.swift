import HeedCore
import SwiftUI
import UniformTypeIdentifiers

/// Tabs and the focused tab's split panes.
struct CenterArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            TabStrip().shotRegion(.tabStrip)
            if let tab = model.currentTab {
                Group {
                    if tab.zoomed, let pane = tab.tree.panes.first(where: { $0.id == tab.focused }) {
                        PaneView(pane: pane, number: (tab.tree.panes.firstIndex(of: pane) ?? 0) + 1, tab: tab)
                    } else {
                        PaneTreeView(tree: tab.tree, tab: tab)
                    }
                }
                .shotRegion(.panes)
                // A pane's terminal must survive re-layout (splits, zoom); identity is the pane id, not position.
                .id(tab.id)
            } else {
                EmptyCenter()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.pane)
    }
}

private struct TabStrip: View {
    @Environment(AppModel.self) private var model
    /// The tab being dragged to a new place.
    @State private var draggedTab: String?

    var body: some View {
        HStack(spacing: 0) {
            // More tabs than fit scroll sideways rather than push the inspector off the window; the active one stays in
            // view.
            if ShotMode.active {
                // Docs shots render offscreen, where a scroll view's content isn't drawn.
                tabs.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) { tabs }
                        .onAppear { reveal(proxy) }
                        .onChange(of: model.currentTab?.id) { reveal(proxy) }
                }
            }
            HStack(spacing: 10) {
                // What the keys do here, as you have them bound: into the terminal in NORMAL, back out in INSERT.
                if model.mode == .insert {
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
                } else {
                    hint(model.keyLabel(for: "mode.insert"), "insert")
                    hint(model.keyLabel(for: "pane.split.right"), "split right")
                    hint(model.keyLabel(for: "pane.split.below"), "below")
                    hint(model.keyLabel(for: "tab.next"), "tab")
                }
                if !model.inspectorVisible {
                    CollapseButton(systemImage: "sidebar.right", key: "zi") { model.toggleInspector() }
                }
            }
            .font(Theme.ui(11.5))
            .padding(.horizontal, 14)
        }
        .frame(height: 36)
        .background(Theme.bg2)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        if let id = model.currentTab?.id { proxy.scrollTo(id) }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.currentTabs.enumerated()), id: \.element.id) { index, tab in
                let on = index == model.currentTabIndex
                HStack(spacing: 8) {
                    if let agent = tab.tree.panes.first(where: { $0.role == .agent }) {
                        let state = (model.agents[agent.id] ?? AgentTab()).state
                        StateGlyph(state: state.state, guessed: state.source == .guessed, size: 11)
                    } else if let command = tab.tree.panes.first(where: { $0.role == .command }),
                              let code = model.commandResults[command.id]
                    {
                        // A pinned command's last run: done when it passed, a red square when it failed.
                        if code == 0 {
                            StateGlyph(state: .done, size: 11)
                        } else {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.err).frame(width: 9, height: 9)
                        }
                    } else if tab.tree.panes.allSatisfy({ $0.role == .browser }) {
                        Image(systemName: "globe").font(.system(size: 10))
                    }
                    Text(tab.title).lineLimit(1).fixedSize()
                    TabCloseButton { model.closeTab(index) }
                }
                .font(Theme.mono(12))
                .foregroundStyle(on ? Theme.fg : Theme.fg3)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(on ? Theme.pane : .clear)
                .overlay(alignment: .bottom) { if on { Theme.inverse.frame(height: 2) } }
                .contentShape(Rectangle())
                .onTapGesture { model.selectTab(index) }
                // Dragged along the strip, a tab takes the place of the one it passes over.
                .onDrag {
                    draggedTab = tab.id
                    return NSItemProvider(object: tab.id as NSString)
                }
                .onDrop(of: [.text], delegate: TabDrop(target: tab.id, dragged: $draggedTab, model: model))
                .id(tab.id)
            }
            Text("+").font(Theme.mono(13)).foregroundStyle(Theme.fg3).padding(.horizontal, 14)
                .frame(height: 36)
                .contentShape(Rectangle())
                .onTapGesture { model.perform(CommandInvocation(name: "tab.new")) }
                .help("New tab (:tab.new)")
        }
    }
}

extension TabStrip {
    /// A key and what it does; nothing when the command has no key.
    @ViewBuilder func hint(_ key: String?, _ label: String) -> some View {
        if let key {
            HStack(spacing: 5) {
                KeyCap(text: key)
                Text(label).foregroundStyle(Theme.fg3)
            }
            .fixedSize()
        }
    }
}

/// A tab dragged over another one moves into its place, so the strip shows the new order while you drag.
private struct TabDrop: DropDelegate {
    let target: String
    @Binding var dragged: String?
    let model: AppModel

    func dropEntered(info _: DropInfo) {
        guard let dragged, dragged != target,
              let index = model.currentTabs.firstIndex(where: { $0.id == target })
        else { return }
        model.moveTab(dragged, to: index)
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

private struct PaneTreeView: View {
    @Environment(AppModel.self) private var model
    let tree: PaneTree
    let tab: PaneTab
    /// Where this part sits in the tab's tree (0 a split's first side, 1 its second): how a divider names its split.
    var path: [Int] = []
    /// The ratio while the divider is dragged; the layout gets it when the mouse is let go.
    @State private var dragging: Double?

    var body: some View {
        switch tree {
        case let .leaf(pane):
            PaneView(pane: pane, number: (tab.tree.panes.firstIndex(of: pane) ?? 0) + 1, tab: tab)
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
                            PaneTreeView(tree: first, tab: tab, path: path + [0]).frame(width: length * shown)
                            PaneTreeView(tree: second, tab: tab, path: path + [1])
                        }
                    } else {
                        VStack(spacing: 1) {
                            PaneTreeView(tree: first, tab: tab, path: path + [0]).frame(height: length * shown)
                            PaneTreeView(tree: second, tab: tab, path: path + [1])
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    ResizeHandle(
                        axis: sideways ? .horizontal : .vertical,
                        moved: { dragging = dragged($0) },
                        ended: {
                            model.setSplitRatio(dragged($0), at: path, inTab: tab.id)
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
}

private struct PaneView: View {
    @Environment(AppModel.self) private var model
    let pane: PaneSpec
    let number: Int
    let tab: PaneTab

    var body: some View {
        let active = pane.id == tab.focused
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(Theme.mono(10.5, weight: active ? .bold : .regular))
                    .foregroundStyle(active ? Theme.ink : Theme.fg)
                    .padding(.horizontal, 5)
                    .background(RoundedRectangle(cornerRadius: 3).fill(active ? Theme.inverse : Theme.selected))
                if pane.role == .browser {
                    BrowserToolbar(pane: pane)
                } else {
                    Text(pane.title)
                    Spacer()
                }
                if pane.role == .agent {
                    let state = (model.agents[pane.id] ?? AgentTab()).state.state
                    Text(state.rawValue).foregroundStyle(stateColor(state))
                }
            }
            .font(Theme.mono(11))
            .foregroundStyle(active ? Theme.fg : Theme.fg3)
            .padding(.horizontal, 10)
            .frame(height: pane.role == .browser ? 30 : 26)
            .background(Theme.paneHeader)

            if ShotMode.active {
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
            // A page reports clicks into it itself; its header holds the address field, which must keep the click.
            if pane.role == .browser { model.focusPane(pane.id) } else { model.clickedPane(pane.id) }
        }
    }

    private func stateColor(_ state: AgentState) -> Color {
        switch state {
        case .working: Theme.busy
        case .blocked, .limited: Theme.block
        case .asking: Theme.ask
        case .done: Theme.done
        case .idle, .exited: Theme.fg3
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
