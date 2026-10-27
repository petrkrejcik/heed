import HeedCore
import SwiftUI

/// The right column: the task (its status, checkout and note), its PR and issue, and its agents' hook events.
struct Inspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let task = model.currentTask {
                section {
                    HStack {
                        SectionHeader(title: "Task")
                        Spacer()
                        CollapseButton(systemImage: "sidebar.right", key: "zi") { model.toggleInspector() }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        field("status", task.status.rawValue, tint: task.status == .blocked ? Theme.block : Theme.fg)
                        field("checkout", Paths.abbreviate(task.directory))
                        if let branch = task.branch { field("branch", branch) }
                        if let port = task.port {
                            field(
                                "kibana", task.running ? "running on :\(port)" : "not running (:\(port))",
                                tint: task.running ? Theme.done : Theme.fg3
                            )
                        }
                        if let epic = task.epic { field("epic", epic) }
                        if let note = task.notePath { field("note", (note as NSString).lastPathComponent) }
                    }
                }
                section {
                    HStack {
                        SectionHeader(title: "Links")
                        Spacer()
                        KeyCap(text: "gB")
                    }
                    let links = model.links(of: task)
                    if links.isEmpty { emptyLinks(task) }
                    ForEach(links, id: \.self) { link in
                        LinkCard(task: task, link: link)
                            .contentShape(Rectangle())
                            // A click opens it here (the PR overlay, the issue reader); ⌘-click on GitHub.
                            .onTapGesture {
                                model.open(link, browser: NSEvent.modifierFlags.contains(.command))
                            }
                            .help("\(link.url)\n⌘-click opens it on GitHub")
                    }
                }
                section {
                    SectionHeader(title: "Agents")
                    let panes = (model.layouts[task.id]?.panes ?? []).filter { $0.role == .agent }
                    if panes.isEmpty {
                        Text("No agent tab.").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                    }
                    ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                        let agent = model.agents[pane.id] ?? AgentTab()
                        HStack(spacing: 8) {
                            StateGlyph(state: agent.state.state, guessed: agent.state.source == .guessed)
                            Text(panes.count > 1 ? "agent \(index + 1)" : "agent").foregroundStyle(Theme.fg)
                            Text(agent.activity.isEmpty ? agent.state.state.rawValue : agent.activity)
                                .foregroundStyle(Theme.fg3)
                                .lineLimit(1)
                        }
                        .font(Theme.mono(11))
                    }
                    let log = model.events[task.id] ?? []
                    ForEach(Array(log.prefix(8).enumerated()), id: \.offset) { _, event in
                        HStack(spacing: 8) {
                            Text(event.at, format: .dateTime.hour().minute().second()).foregroundStyle(Theme.fg3)
                            StateGlyph(state: event.state)
                            Text(event.state.rawValue).foregroundStyle(Theme.fg)
                            Text(event.reason ?? "").foregroundStyle(Theme.fg3).lineLimit(1).truncationMode(.tail)
                        }
                        .font(Theme.mono(11))
                    }
                }
            }
            Spacer()
        }
        .frame(width: model.inspectorWidth)
        .background(Theme.bg2)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
    }

    private func field(_ name: String, _ value: String, tint: Color = Theme.fg) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).foregroundStyle(Theme.fg3).frame(width: 64, alignment: .leading)
            Text(value).foregroundStyle(tint).lineLimit(1).truncationMode(.middle)
        }
        .font(Theme.mono(11.5))
    }

    /// No PR and no issue yet: what comes next. A branch offers the compare page that opens a PR.
    @ViewBuilder private func emptyLinks(_ task: WorkTask) -> some View {
        if let branch = task.branch, task.worktree != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("No PR yet.").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                Text("Open a PR on GitHub ↗")
                    .font(Theme.ui(11.5, weight: .medium))
                    .foregroundStyle(Theme.busy)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.openLink(IssueLinks.compareURL(repo: Kibana.repo, branch: branch), from: task.id)
                    }
            }
        } else {
            Text("No PR or issue yet. An agent's `gh pr create` links its PR; `heed pr add <url>` or "
                + "`heed issue add <url>` link one by hand.")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.fg3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

/// `open`, `draft`, `merged`, `closed`.
struct StateTag: View {
    let state: PullRequest.State
    let draft: Bool

    var body: some View {
        let (text, tint): (String, Color) = switch state {
        case .open: draft ? ("draft", Theme.fg2) : ("open", Theme.done)
        case .merged: ("merged", Theme.ask)
        case .closed: ("closed", Theme.err)
        }
        Text(text)
            .font(Theme.mono(10.5))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.16)))
    }
}

/// One of a task's links in the inspector: a PR (its state, checks, review and what holds it back from green) or
/// an issue (its title and state).
private struct LinkCard: View {
    @Environment(AppModel.self) private var model
    let task: WorkTask
    let link: TaskLink

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch link {
            case let .pull(ref): pull(ref)
            case let .issue(ref): issue(ref)
            case let .repo(repo): Text(repo.slug).font(Theme.mono(11.5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg3))
    }

    @ViewBuilder private func pull(_ ref: PullRef) -> some View {
        let pull = model.github.pull(ref)
        HStack {
            Image(systemName: "arrow.triangle.pull").font(.system(size: 10)).foregroundStyle(Theme.fg3)
            Text(verbatim: "\(ref.repo.name) #\(ref.number)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
            Spacer()
            if let pull { StateTag(state: pull.state, draft: pull.isDraft) }
        }
        Text(pull?.title ?? task.title).font(Theme.ui(13, weight: .medium)).lineLimit(2)
        if let pull {
            HStack(spacing: 8) {
                CheckBar(checks: pull.checks)
                Text(pull.checks.text)
                    .foregroundStyle(pull.checks.failed > 0 ? Theme.err : Theme.fg2)
                Text("· \(pull.review?.text ?? "no review")").foregroundStyle(Theme.fg3)
            }
            .font(Theme.ui(11.5))
            .lineLimit(1)
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            PullMark(status: model.pullStatus(for: ref), compact: true)
            Text(verdictLine(ref, pull))
                .foregroundStyle(pull?.state == .open ? Theme.fg2 : Theme.fg3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.mono(11))
    }

    /// What holds an open PR back from green, from its detail once fetched.
    private func verdictLine(_ ref: PullRef, _ pull: PullRequest?) -> String {
        guard let pull else { return "waiting for the next sync" }
        guard pull.state == .open else { return pull.state == .merged ? "done" : "closed without merging" }
        guard let detail = model.pullDetails[ref.description] else { return "details not fetched yet" }
        guard let blocker = GreenVerdict.of(detail).blocker else { return "nothing left to fix" }
        return "\(blocker.name.lowercased()): \(blocker.detail)"
    }

    @ViewBuilder private func issue(_ ref: IssueRef) -> some View {
        let info = model.issueInfo[ref]
        let known = model.issue(for: ref)
        HStack {
            Image(systemName: "smallcircle.filled.circle").font(.system(size: 10)).foregroundStyle(Theme.fg3)
            Text(verbatim: "\(ref.repo.name) #\(ref.number)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
            Spacer()
            if let info {
                let (text, tint) = info.closed ? ("closed", Theme.ask) : ("open", Theme.done)
                Text(text)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.16)))
            }
        }
        Text(known?.title ?? "issue \(ref.repo.slug)#\(ref.number)")
            .font(Theme.ui(13, weight: .medium))
            .foregroundStyle(known == nil ? Theme.fg3 : Theme.fg)
            .lineLimit(2)
    }
}
