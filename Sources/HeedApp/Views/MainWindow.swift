import HeedCore
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            TitleBar().shotRegion(.titleBar)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    switch model.view {
                    case .tasks:
                        if model.sidebarCollapsed {
                            TaskRail().shotRegion(.rail)
                        } else {
                            let width = geometry.size.width < 1000 ? min(model.sidebarWidth, 260) : model.sidebarWidth
                            Sidebar(width: width).shotRegion(.sidebar)
                                .overlay(alignment: .trailing) {
                                    ColumnEdge(width: width) { model.resizeSidebar(to: $0, done: $1) }.offset(x: 3)
                                }
                                // Above the center, so the edge's outer half takes the mouse too.
                                .zIndex(1)
                        }
                        CenterArea().shotRegion(.center)
                        // The inspector gives way first on narrow windows; `zi` hides it outright.
                        if model.inspectorVisible, geometry.size.width >= 1180 {
                            Inspector().shotRegion(.inspector)
                                .overlay(alignment: .leading) {
                                    ColumnEdge(width: model.inspectorWidth, growsLeft: true) {
                                        model.resizeInspector(to: $0, done: $1)
                                    }
                                    .offset(x: -3)
                                }
                                .zIndex(1)
                        }
                    case .inbox:
                        InboxView()
                    case .issues:
                        IssuesView()
                    case .prs:
                        PullRequestsView()
                    }
                }
            }
            StatusBar().shotRegion(.statusBar)
        }
        .background(Theme.bg)
        .overlay {
            if model.overlay == .pr { PullOverlayView().shotRegion(.reader).padding(.top, 44).padding(.bottom, 28) }
        }
        .overlay {
            if model.reader != nil { ReaderView().shotRegion(.reader).padding(.top, 44).padding(.bottom, 28) }
        }
        .overlay {
            if model.issueReader != nil { IssueReaderView().shotRegion(.reader).padding(.top, 44).padding(.bottom, 28) }
        }
        .overlay {
            if let form = model.newTask { NewTaskView(form: form) }
        }
        .overlay {
            if model.resume != nil { ResumeView() }
        }
        .overlay {
            if let picker = model.linkPicker { LinkPickerView(picker: picker) }
        }
        .overlay {
            if let picker = model.tabPicker { TabPickerView(picker: picker) }
        }
        .overlay {
            if let confirmation = model.confirmation { ConfirmationView(confirmation: confirmation) }
        }
        .overlay {
            if model.firstRun != nil { FirstRunView() }
        }
        .overlay {
            if model.overlay == .help { HelpOverlay() }
        }
        .overlay(alignment: .bottom) {
            if model.mode == .command { CommandLineView().padding(.bottom, 28) }
        }
        .overlay(alignment: .bottom) {
            LeaderHints().padding(.bottom, 28)
        }
        // After the overlays, so the dialogs inherit it too.
        .foregroundStyle(Theme.fg)
        .ignoresSafeArea()
        .onAppear {
            let open = openSettings
            model.openSettings = { open() }
            let reopen = openWindow
            model.reopenWindow = { reopen(id: "main") }
        }
    }
}

struct TitleBar: View {
    @Environment(AppModel.self) private var model
    @State private var leftWidth: CGFloat = 0
    @State private var rightWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            // Narrow windows keep only the active view's name and drop the hint text.
            let compact = geometry.size.width < 1180
            let width = geometry.size.width
            // What you are looking at sits in the middle of the window when the middle is free, else in the gap
            // between the views and the status.
            let gap: CGFloat = 24
            let centred = width - 2 * max(leftWidth, rightWidth) - 2 * gap
            let between = width - leftWidth - rightWidth - 2 * gap
            ZStack {
                HStack(spacing: 0) {
                    HStack(spacing: 0) {
                        // Room for the window's own traffic lights.
                        Color.clear.frame(width: 60, height: 1)
                        views(compact: compact)
                    }
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leftWidth = $0 }
                    Spacer(minLength: 0)
                    HStack(spacing: compact ? 10 : 16) { status(compact: compact) }
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rightWidth = $0 }
                }
                if centred >= 160 {
                    crumb.frame(maxWidth: centred)
                } else if between >= 80 {
                    crumb.frame(maxWidth: between)
                        .offset(x: (leftWidth - rightWidth) / 2)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .font(Theme.ui(12))
        .foregroundStyle(Theme.fg2)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Theme.bg2)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    @ViewBuilder private func status(compact: Bool) -> some View {
        syncStatus
        if model.blockedCount > 0 {
            Label { Text(compact ? "\(model.blockedCount)" : "\(model.blockedCount) blocked").fixedSize() }
                icon: { StateGlyph(state: .blocked) }
        }
        if model.askingCount > 0 {
            Label { Text(compact ? "\(model.askingCount)" : "\(model.askingCount) asking").fixedSize() }
                icon: { StateGlyph(state: .asking) }
        }
        HStack(spacing: 6) {
            KeyCap(text: "ga")
            if !compact { Text("next attention").foregroundStyle(Theme.fg3).fixedSize() }
        }
    }

    /// Unread inbox items; PRs that need you.
    private func badge(_ view: AppView) -> Int {
        switch view {
        case .inbox: model.github.inbox.count(where: \.unread)
        case .prs: model.github.pullsNeedingAttention
        default: 0
        }
    }

    @ViewBuilder private var syncStatus: some View {
        if model.view == .inbox || model.view == .issues || model.view == .prs {
            Group {
                if model.syncing {
                    Text("syncing…")
                } else if model.github.status.isOffline {
                    Text("offline").foregroundStyle(Theme.block)
                } else if let synced = model.github.syncedAt {
                    if case let .partial(hidden, _) = model.github.status {
                        Text("synced \(Clock.relative(synced)) · \(hidden) hidden")
                            .help("Items in orgs the gh token is not authorized for (SAML).")
                    } else {
                        Text("synced \(Clock.relative(synced))")
                    }
                }
            }
            .foregroundStyle(Theme.fg3)
            .fixedSize()
        }
    }

    /// What you are looking at: the task's worktree, title and PR, or the PR or issue under the cursor (or open in a
    /// reader).
    @ViewBuilder private var crumb: some View {
        if let context = model.titleContext {
            HStack(spacing: 6) {
                // The repo and the branch or number stay whole; the title gives way.
                if let lead = context.lead {
                    Text(lead).foregroundStyle(Theme.fg2).fixedSize()
                    Text("/").foregroundStyle(Theme.dim).fixedSize()
                }
                Text(context.main).fontWeight(.medium).foregroundStyle(Theme.fg).truncationMode(.middle)
                    .layoutPriority(1)
                if let detail = context.detail { Text(detail).foregroundStyle(Theme.fg3).truncationMode(.tail) }
            }
            .font(Theme.mono(12))
            .lineLimit(1)
            .clipped()
        }
    }

    /// The views as names with their key (`Inbox 7 gm`); narrow windows drop the keys, never the names.
    private func views(compact: Bool) -> some View {
        viewTabs(compact: compact).shotRegion(.viewTabs)
    }

    private func viewTabs(compact: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(AppView.allCases.enumerated()), id: \.element) { index, view in
                // A hairline between views: separate without boxing them in.
                if index > 0 { Theme.line.frame(width: 1, height: 14) }
                ViewTab(
                    view: view,
                    active: model.view == view,
                    count: badge(view),
                    key: compact ? nil : model.keyCap(for: view.command)
                )
                .onTapGesture { model.perform(CommandInvocation(name: view.command)) }
            }
        }
    }
}

private struct ViewTab: View {
    let view: AppView
    let active: Bool
    let count: Int
    let key: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(view.title).foregroundStyle(active ? Theme.fg : Theme.fg2)
            if count > 0 { Text("\(count)").foregroundStyle(Theme.block) }
            if let key {
                Text(key)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.fg3)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.keyCapBorder))
            }
        }
        .font(Theme.ui(12.5, weight: active ? .semibold : .regular))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, key == nil ? 7 : 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.selected : .clear))
        .contentShape(Rectangle())
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Text(model.mode.label)
                .font(Theme.mono(11.5, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .background(Theme.modeColor(model.mode))
            if model.filtering {
                filterLine
            } else {
                if let branch = model.currentTask?.branch {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                        Text(branch)
                    }
                    .padding(.horizontal, 12)
                }
                if let layout = model.currentLayout, let pane = layout.focusedPane,
                   let index = layout.groups.firstIndex(where: { $0.id == layout.focused?.id })
                {
                    let title = pane.role == .browser ? BrowserAddress.tabTitle(title: pane.title, url: pane.url)
                        : pane.title
                    Text("pane \(index + 1) · \(title)")
                        .foregroundStyle(Theme.fg3)
                        .padding(.horizontal, 12)
                }
                if let flash = model.flash {
                    Text(flash).foregroundStyle(Theme.block).lineLimit(1).truncationMode(.middle).padding(
                        .horizontal,
                        12
                    )
                } else if let problem = model.configProblems.first {
                    Text("config.toml: \(problem.description)").foregroundStyle(Theme.err).lineLimit(1).padding(
                        .horizontal,
                        12
                    )
                } else if let problem = model.keyProblems.first {
                    Text("config: \(problem.description)").foregroundStyle(Theme.err).padding(.horizontal, 12)
                } else if let problem = model.tools?.problems.first {
                    Text(problem).foregroundStyle(Theme.err).lineLimit(1).truncationMode(.middle).padding(
                        .horizontal,
                        12
                    )
                }
            }
            Spacer()
            Text(model.pendingKeys).foregroundStyle(Theme.fg).padding(.horizontal, 12)
            Text(hints).foregroundStyle(Theme.fg3).lineLimit(1).truncationMode(.head).padding(.horizontal, 12)
            Text(position).foregroundStyle(Theme.fg2).padding(.horizontal, 12)
        }
        .font(Theme.mono(11.5))
        .frame(height: 28)
        .background(Theme.bg3)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    private var position: String {
        switch model.view {
        case .inbox, .issues, .prs:
            let count = model.itemIDs(model.view).count
            return "\(count == 0 ? 0 : model.cursor(in: model.view) + 1)/\(count)"
        case .tasks: return "\(model.list.ordered.isEmpty ? 0 : model.cursor + 1)/\(model.list.ordered.count)"
        }
    }

    /// `/` types here, whichever view it filters; the view's pill mirrors it.
    private var filterLine: some View {
        HStack(spacing: 0) {
            Text("/").foregroundStyle(Theme.ask)
            Text(model.filter(for: model.view)).foregroundStyle(Theme.fg)
            Rectangle().fill(Theme.fg).frame(width: 7, height: 14)
            Text(
                "  \(model.view.title.lowercased()) · \(model.filterMatches) match\(model.filterMatches == 1 ? "" : "es")"
            )
            .foregroundStyle(Theme.fg3)
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
    }

    private var hints: String {
        switch model.mode {
        case let .normal where model.confirmation.map { !$0.alternatives.isEmpty } == true:
            "y or ↩ \(model.confirmation?.accept.lowercased() ?? "confirm") · "
                + (model.confirmation?.alternatives ?? []).map { "\($0.key) \($0.label.lowercased())" }
                .joined(separator: " · ")
                + " · ⎋ \(model.confirmation?.cancel.lowercased() ?? "cancel")"
        case .normal where model.confirmation != nil: "y or ↩ confirm · n, ⎋ or q cancel"
        case .normal where model.newTask != nil: "type a title · ↩ create · ⎋ cancel"
        case .normal where model.filtering: "words match anywhere · ⌃w word · ⌃u clear · ↩ keep · ⎋ clear"
        case .normal where model.issueReader != nil: "s new task · gB browser · ⎋ back"
        case .normal where model.reader != nil || model.overlay == .pr:
            "\(model.keyText(for: "pr.start")) new task · gS task · gB browser · ⎋ back"
        case .normal where model.view == .inbox: "↩ read · space pick · v range · s new task · x mark read · t unread/all · / filter"
        case .normal where model.view == .issues: "↩ read · space pick · s new task · t filter · ⇥ repo · / filter"
        case .normal where model.view == .prs: "↩ open · v select · gS task · r sync"
        case .normal where model.focusedDiffPane != nil:
            "j k file · n hunk · ⇥ scope · c commit · t side by side · r read again · h l pane · gt tab"
        case .normal: "i insert · o new task · m pin · { } group · : command · ? keys"
        case .insert: "⇧⎋ or \(KeyCapText.of(model.config.insertEscape)) normal · ⌘/ keys"
        case .visual where model.view == .inbox:
            "\(model.pickedIDs(model.view).count) selected · space toggle · s new task · x read · ⎋ cancel"
        case .visual where model.view == .issues:
            "\(model.pickedIDs(model.view).count) selected · space toggle · s new task · ⎋ cancel"
        case .visual: "\(model.pickedIDs(model.view).count) selected · space toggle · ⎋ cancel"
        case .command: "⇥ complete · ↩ run · ⎋ cancel"
        case .hint: "type a label · ⎋ cancel"
        }
    }
}

/// Key notation as key-cap text: `<C-w>v` reads `⌃w v`.
enum KeyCapText {
    static func of(_ notation: String) -> String {
        guard let strokes = try? KeyNotation.parse(notation) else { return notation }
        return of(strokes)
    }

    /// Runs of plain characters share a cap (`gg`, `'1`); a modified or named key stands alone (`⌃w v`).
    static func of(_ strokes: [KeyStroke]) -> String {
        var parts: [String] = []
        var previousPlain = false
        for stroke in strokes {
            let plain = stroke.modifiers.isEmpty && !stroke.isNamed
            if plain, previousPlain {
                parts[parts.count - 1] += stroke.glyph
            } else {
                parts.append(stroke.glyph)
            }
            previousPlain = plain
        }
        return parts.joined(separator: " ")
    }
}

struct CommandLineView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.commandCompletions, id: \.name) { spec in
                HStack {
                    Text(spec.name).font(Theme.mono(12))
                    if let args = spec.arguments { Text(args).font(Theme.mono(12)).foregroundStyle(Theme.fg3) }
                    Spacer()
                    Text(spec.summary).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            HStack(spacing: 0) {
                Text(":").foregroundStyle(Theme.ask)
                Text(model.commandText)
                Rectangle().fill(Theme.fg).frame(width: 7, height: 15)
                Spacer()
            }
            .font(Theme.mono(13))
            .padding(12)
        }
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.5), radius: 20).shotRegion(.commandLine)
    }
}

/// Asks before anything destructive: what will happen, what is kept and why; y or ↩ goes ahead, n, ⎋ or q does not.
struct ConfirmationView: View {
    @Environment(AppModel.self) private var model
    let confirmation: AppModel.Confirmation

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(alignment: .leading, spacing: 14) {
                Text(confirmation.title).font(Theme.ui(15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(confirmation.lines, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("·").foregroundStyle(confirmation.destructive ? Theme.err : Theme.fg3)
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.fg2)
                if !confirmation.kept.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Kept").font(Theme.ui(11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.fg3)
                        ForEach(confirmation.kept, id: \.self) { line in
                            Text(line).font(Theme.mono(11.5)).foregroundStyle(Theme.block)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Spacer()
                    // Cancelling that does what accepting does (Keep) needs no button of its own; ⎋ still works.
                    if confirmation.cancel != confirmation.accept {
                        HStack(spacing: 6) {
                            Text(confirmation.cancel)
                            KeyCap(text: "n")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                        .contentShape(Rectangle())
                        .onTapGesture { model.cancelConfirmation() }
                    }
                    ForEach(confirmation.alternatives, id: \.key) { alternative in
                        HStack(spacing: 6) {
                            Text(alternative.label)
                            KeyCap(text: alternative.key)
                        }
                        .foregroundStyle(alternative.destructive ? Theme.err : Theme.fg)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(alternative.destructive ? Theme.err.opacity(0.6) : Theme.line))
                        .contentShape(Rectangle())
                        .onTapGesture { model.chooseAlternative(alternative.key) }
                    }
                    HStack(spacing: 6) {
                        Text(confirmation.accept).fontWeight(.semibold)
                        KeyCap(text: "↩")
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(confirmation.destructive ? Theme.err : Theme.inverse))
                    .contentShape(Rectangle())
                    .onTapGesture { model.acceptConfirmation() }
                }
                .font(Theme.ui(12.5))
            }
            .padding(22)
            .frame(width: 480)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.5), radius: 30).shotRegion(.confirm)
        }
    }
}

/// `gB` with several places to go: the task's PR and issues, numbered.
struct LinkPickerView: View {
    @Environment(AppModel.self) private var model
    let picker: LinkPicker

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .onTapGesture { model.cancelLinkPicker() }
            VStack(alignment: .leading, spacing: 0) {
                Text(picker.title).font(Theme.ui(15, weight: .semibold)).padding(18)
                ForEach(Array(picker.links.enumerated()), id: \.element) { index, link in
                    HStack(spacing: 10) {
                        Text(index < 9 ? "\(index + 1)" : " ").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                            .frame(width: 12)
                        Image(systemName: icon(link)).font(.system(size: 10)).foregroundStyle(Theme.fg3)
                        Text(link.label).font(Theme.mono(12.5, weight: .semibold))
                        Text(title(link)).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(state(link)).font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(index == picker.cursor ? Theme.bg3 : .clear)
                    .overlay(alignment: .leading) { if index == picker.cursor { Theme.block.frame(width: 2) } }
                    .contentShape(Rectangle())
                    .onTapGesture { model.open(link, browser: true) }
                }
                HStack(spacing: 14) {
                    hint("1–9", "open")
                    hint("j k ↩", "move, open")
                    hint("a", "open all")
                    hint("⎋", "close")
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Theme.line.frame(height: 1) }
            }
            .frame(width: 560, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.5), radius: 30)
            .shotRegion(.picker)
        }
    }

    private func icon(_ link: TaskLink) -> String {
        switch link {
        case .pull: "arrow.triangle.pull"
        case .issue: "smallcircle.filled.circle"
        case .repo: "folder"
        }
    }

    private func title(_ link: TaskLink) -> String {
        switch link {
        case let .pull(ref): model.github.pull(ref)?.title ?? ""
        case let .issue(ref): model.issue(for: ref)?.title ?? ""
        case .repo: ""
        }
    }

    private func state(_ link: TaskLink) -> String {
        switch link {
        case let .pull(ref): model.github.pull(ref).map { $0.state.rawValue.lowercased() } ?? ""
        case let .issue(ref): model.issueInfo[ref].map { $0.closed ? "closed" : "open" } ?? ""
        case .repo: ""
        }
    }

    private func hint(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(text: keys)
            Text(text).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
        }
    }
}

/// `⌘T`: what the new tab shows, one key each.
struct TabPickerView: View {
    @Environment(AppModel.self) private var model
    let picker: NewTabPicker

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .onTapGesture { model.cancelTabPicker() }
            VStack(alignment: .leading, spacing: 0) {
                Text("New tab").font(Theme.ui(15, weight: .semibold)).padding(18)
                ForEach(NewTabPicker.Kind.allCases, id: \.self) { kind in
                    HStack(spacing: 10) {
                        KeyCap(text: kind.key)
                        Image(systemName: kind == .page ? "globe" : "terminal").font(.system(size: 11))
                            .foregroundStyle(Theme.fg3).frame(width: 16)
                        Text(kind.label).font(Theme.ui(13))
                        Spacer(minLength: 8)
                        if kind == picker.last { Text("↩").font(Theme.mono(11)).foregroundStyle(Theme.fg3) }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(kind == picker.last ? Theme.bg3 : .clear)
                    .overlay(alignment: .leading) { if kind == picker.last { Theme.block.frame(width: 2) } }
                    .contentShape(Rectangle())
                    .onTapGesture { model.openTab(kind) }
                }
                HStack(spacing: 5) {
                    KeyCap(text: "⎋")
                    Text("close").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Theme.line.frame(height: 1) }
            }
            .frame(width: 320, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.5), radius: 30)
            .shotRegion(.picker)
        }
    }
}
