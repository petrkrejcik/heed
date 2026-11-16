import HeedCore
import SwiftUI

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    var width: CGFloat = 330

    var body: some View {
        let list = model.list
        VStack(spacing: 0) {
            HStack {
                SectionHeader(title: "Tasks")
                Spacer()
                CollapseButton(systemImage: "sidebar.left", key: "zs") { model.toggleSidebar() }
                FilterPill(view: .tasks)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            ScrollViewReader { proxy in
                ListScroll {
                    ListStack(alignment: .leading, spacing: 0) {
                        ForEach(list.sections, id: \.group) { section in
                            VStack(alignment: .leading, spacing: 0) {
                                groupHeader(section, pins: list.pins.count)
                                ForEach(section.collapsed ? [] : section.tasks) { task in
                                    let index = list.index(of: task.id) ?? 0
                                    TaskRow(
                                        task: task,
                                        rollup: list.rollup(of: task.id),
                                        isCursor: index == model.cursor,
                                        pinNumber: list.pins.firstIndex(of: task).map { $0 + 1 },
                                        hint: model.hintLabel(for: .task(task.id)),
                                        pull: model.pullTag(of: task)
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.clickTask(task.id) }
                                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                                        model.clickTask(task.id, insert: true)
                                    })
                                    .id(task.id)
                                }
                            }
                        }
                    }
                }
                .onChange(of: model.cursor) {
                    if let id = model.currentTask?.id { proxy.scrollTo(id) }
                }
            }

            if list.all.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No tasks yet.").foregroundStyle(Theme.fg2)
                    HStack(spacing: 6) {
                        KeyCap(text: model.keyCap(for: "task.new") ?? ":task.new")
                        Text("new task").foregroundStyle(Theme.fg3)
                    }
                }
                .font(Theme.ui(12.5))
                .padding(16)
            }
            Spacer(minLength: 0)
        }
        .frame(width: width)
        .background(Theme.bg2)
        .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
    }

    /// A section's name and count, with a chevron; a click collapses or expands it.
    private func groupHeader(_ section: TaskList.Section, pins: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: section.collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.fg3)
                .frame(width: 10)
            if section.group == .pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.fg3)
            }
            let count = section.group == .pinned ? "\(pins)/\(TaskGroup.maxPins)" : "\(section.tasks.count)"
            SectionHeader(title: "\(section.group.rawValue) · \(count)")
            Spacer()
            if section.group == .pinned { KeyCap(text: "'") }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture { model.clickSection(section.group) }
        .help("collapse / expand (\(model.keyCap(for: "section.toggle") ?? "za"))")
    }
}

/// One task: the most urgent agent's glyph, its title and pin, then its tags (Kibana when it runs, its PR, its note
/// and issue, the prompt cache countdown) when it has any. What the agent is doing is in the tooltip.
struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: WorkTask
    let rollup: TaskRollup
    let isCursor: Bool
    let pinNumber: Int?
    let hint: String?
    var pull: PullTag?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let agent = rollup.agent {
                    StateGlyph(state: agent.state, guessed: agent.source == .guessed)
                } else {
                    StateGlyph(state: .exited)
                }
            }
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(Theme.ui(13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let pinNumber { KeyCap(text: "'\(pinNumber)") }
                }
                tags
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .background(isCursor ? Theme.bg3 : .clear)
        .overlay(alignment: .topLeading) {
            if let hint { HintBadge(label: hint).padding(.leading, 8).padding(.top, 8) }
        }
        .help(activity.isEmpty ? task.title : "\(task.title)\n\(activity)")
    }

    /// The tags line. With a prompt cache counting down it redraws on its own once a minute, on the minute the
    /// countdown changes (counted from the turn), and nothing else in the list does.
    @ViewBuilder private var tags: some View {
        if let cache = PromptCache.countdown(turns: rollup.cacheTurns, now: Clock.now) {
            TimelineView(.periodic(from: cache.turnEndedAt, by: 60)) { _ in
                TaskTagsLine(tags: tagList(now: Clock.now), colors: model.tagColors, open: open)
            }
        } else {
            TaskTagsLine(tags: tagList(now: Clock.now), colors: model.tagColors, open: open)
        }
    }

    private func open(_ tag: TaskTag) { model.clickTag(tag, of: task.id) }

    private func tagList(now: Date) -> [TaskTag] { TaskTag.of(task, rollup: rollup, pull: pull, now: now) }

    /// "2 agents · running jest · 2m"; a single agent just says what it does.
    private var activity: String {
        let count = rollup.agentCount > 1 ? "\(rollup.agentCount) agents" : nil
        return [count, rollup.activity.isEmpty ? nil : rollup.activity].compactMap(\.self).joined(separator: " · ")
    }
}

/// A row's tags; nothing at all (no line, no gap) when there are none. A click on one opens it. Every tag has a fixed
/// width, so they line up down the list: the PR pill at the left edge, then the note and the issue; Kibana and the
/// countdown at the right edge, the countdown's place kept when only Kibana shows.
struct TaskTagsLine: View {
    let tags: [TaskTag]
    var colors = TagColors.none
    var open: (TaskTag) -> Void = { _ in }

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 8) {
                ForEach(tags.filter { !$0.isLive }, id: \.self) { tag in
                    switch tag {
                    case let .pull(pull): TagButton { open(tag) } label: { PullTagMark(tag: pull) }
                    case let .note(_, names) where !names.isEmpty:
                        TagButton { open(tag) } label: { NoteTagsMark(tags: names, colors: colors) }
                            .layoutPriority(-1)
                    case .note: TagButton { open(tag) } label: { NoteMark() }
                    case let .issue(ref): TagButton { open(tag) } label: { IssueMark(ref: ref) }
                    case .kibana, .cache: EmptyView()
                    }
                }
                Spacer(minLength: 8)
                if let port = kibanaPort {
                    TagButton { open(.kibana(port: port)) } label: { KibanaMark(port: port) }
                }
                if kibanaPort != nil || countdown != nil { CacheMark(countdown: countdown) }
            }
            .lineLimit(1)
            .padding(.top, 5)
        }
    }

    private var kibanaPort: Int? {
        tags.lazy.compactMap { if case let .kibana(port) = $0 { port } else { nil } }.first
    }

    private var countdown: PromptCache.Countdown? {
        tags.lazy.compactMap { if case let .cache(countdown) = $0 { countdown } else { nil } }.first
    }
}

/// A tag that opens something: a plain button with the link pointer, so the click is the tag's and not the row's.
struct TagButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(.plain)
            .pointerStyle(.link)
    }
}

/// A task's PR as GitHub labels its state: a filled pill, green Open, grey Draft, violet Merged, red Closed, all as
/// wide as Merged. After it, the CI or review mark when there is something to act on (failing, conflict, threads), in
/// a place kept for it either way. The number is in the tooltip.
struct PullTagMark: View {
    let tag: PullTag

    var body: some View {
        HStack(spacing: 3) {
            ZStack {
                label("Merged").hidden()
                label(tag.state?.label ?? "PR")
            }
            .foregroundStyle(tag.state == nil ? Theme.fg2 : Theme.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color))
            .overlay { if tag.state == nil { Capsule().strokeBorder(Theme.line) } }
            ZStack {
                if let alert = tag.alert { PullMark(status: alert, compact: true) }
            }
            .frame(width: 10, alignment: .leading)
        }
        .fixedSize()
        .help(help)
    }

    private func label(_ text: String) -> some View {
        HStack(spacing: 3) {
            PullGlyph(state: tag.state).frame(width: 9, height: 9)
            Text(text).font(Theme.ui(10.5, weight: .semibold))
        }
    }

    private var color: Color {
        switch tag.state {
        case .draft: Theme.fg3
        case .open: Theme.done
        case .merged: Theme.ask
        case .closed: Theme.err
        case nil: .clear
        }
    }

    private var help: String {
        let alert = tag.alert.map { " · " + PullMark(status: $0).text } ?? ""
        return "PR #\(tag.number) \(tag.state?.rawValue ?? "not synced yet")\(alert). Click to open it."
    }
}

/// GitHub's pull request glyph for a state, drawn on a 16-point grid: two branches with rings at their ends; the right
/// one ends in an arrow (open), dots (draft) or a cross (closed); merged joins it into the left one.
struct PullGlyph: View {
    let state: PullTag.State?

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 16, y: size.height / 16)
            let line = StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
            func ring(_ x: CGFloat, _ y: CGFloat) {
                context.stroke(
                    Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)),
                    with: .foreground,
                    style: line
                )
            }
            func stroke(_ build: (inout Path) -> Void) {
                var path = Path()
                build(&path)
                context.stroke(path, with: .foreground, style: line)
            }
            ring(3.5, 3)
            if state == .merged {
                ring(12.5, 9)
                stroke {
                    $0.move(to: CGPoint(x: 3.5, y: 5))
                    $0.addLine(to: CGPoint(x: 3.5, y: 15))
                    $0.move(to: CGPoint(x: 3.5, y: 5.5))
                    $0.addQuadCurve(to: CGPoint(x: 10.5, y: 9), control: CGPoint(x: 4.5, y: 9))
                }
                return
            }
            ring(3.5, 13)
            ring(12.5, 13)
            stroke {
                $0.move(to: CGPoint(x: 3.5, y: 5))
                $0.addLine(to: CGPoint(x: 3.5, y: 11))
            }
            switch state {
            case .draft:
                for y in [3.0, 7.5] {
                    context.fill(Path(ellipseIn: CGRect(x: 11.5, y: y - 1, width: 2, height: 2)), with: .foreground)
                }
            case .closed:
                stroke {
                    $0.move(to: CGPoint(x: 10.5, y: 1.5))
                    $0.addLine(to: CGPoint(x: 14.5, y: 5.5))
                    $0.move(to: CGPoint(x: 14.5, y: 1.5))
                    $0.addLine(to: CGPoint(x: 10.5, y: 5.5))
                    $0.move(to: CGPoint(x: 12.5, y: 8))
                    $0.addLine(to: CGPoint(x: 12.5, y: 11))
                }
            default:
                stroke {
                    $0.move(to: CGPoint(x: 12.5, y: 11))
                    $0.addLine(to: CGPoint(x: 12.5, y: 5.5))
                    $0.addQuadCurve(to: CGPoint(x: 10, y: 3), control: CGPoint(x: 12.5, y: 3))
                    $0.addLine(to: CGPoint(x: 7, y: 3))
                    $0.move(to: CGPoint(x: 9, y: 1))
                    $0.addLine(to: CGPoint(x: 7, y: 3))
                    $0.addLine(to: CGPoint(x: 9, y: 5))
                }
            }
        }
    }
}

/// The task's note as its tags, each a pill in the colour the Kanban gives it; a click opens the note as a note tab.
/// When the row is short of room the pills give way first, cut at the end.
struct NoteTagsMark: View {
    let tags: [String]
    let colors: TagColors

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                let hue = colors.hue(of: tag)
                Text(verbatim: tag)
                    .font(Theme.ui(10.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Theme.tagText(hue: hue))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Theme.tagBackground(hue: hue)))
            }
        }
        .help("The task's note (\(tags.joined(separator: ", "))). Click to open it.")
    }
}

/// The task's note when it has no tags: a click opens it as a note tab.
struct NoteMark: View {
    var body: some View {
        Image(systemName: "doc.text")
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.fg3)
            .frame(width: 14)
            .help("The task's note. Click to open it.")
    }
}

/// The task's issue (the note's `issue:`): a click opens it on GitHub, in Heed.
struct IssueMark: View {
    let ref: IssueRef

    var body: some View {
        Image(systemName: "smallcircle.filled.circle")
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.fg3)
            .frame(width: 14)
            .help("Issue #\(ref.number). Click to open it.")
    }
}

/// The prompt cache's minutes left, amber in its last five, as wide as `60m` and right-aligned. Without a countdown it
/// keeps its place empty, so Kibana's K stays in line.
struct CacheMark: View {
    let countdown: PromptCache.Countdown?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "hourglass").font(.system(size: 9.5))
            ZStack(alignment: .trailing) {
                Text(verbatim: "00m").hidden()
                Text(verbatim: "\(countdown?.minutesLeft ?? 0)m")
            }
            .font(Theme.mono(10.5))
        }
        .foregroundStyle(countdown?.isWarning == true ? Theme.block : Theme.fg3)
        .opacity(countdown == nil ? 0 : 1)
        .fixedSize()
        .help(countdown.map {
            "Prompt cache: \($0.minutesLeft) min left. It lasts an hour from the agent's last turn; "
                + "a prompt sent before then is cheaper and faster."
        } ?? "")
    }
}

/// Kibana running for a task: a K, its port in the tooltip.
struct KibanaMark: View {
    let port: Int

    var body: some View {
        Image(systemName: "k.square.fill")
            .font(.system(size: 11))
            .foregroundStyle(Theme.done)
            .help("Kibana running on localhost:\(port). Click to open it.")
    }
}

/// HINT mode's letter badge.
struct HintBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(Theme.mono(11, weight: .bold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.modeColor(.hint)))
            .shadow(color: .black.opacity(0.4), radius: 3)
    }
}

/// The collapsed sidebar: one row per task of the open sections (the rows the cursor walks) with its number, agent
/// glyph and pin, so moving and jumping still work; a short line where a section starts.
struct TaskRail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let list = model.list
        VStack(spacing: 0) {
            CollapseButton(systemImage: "sidebar.left", key: "zs") { model.toggleSidebar() }
                .padding(.vertical, 12)
            ListScroll {
                VStack(spacing: 2) {
                    ForEach(Array(list.ordered.enumerated()), id: \.element.id) { index, task in
                        let isCursor = index == model.cursor
                        let agent = list.rollup(of: task.id).agent
                        if index > 0, list.group(of: task.id) != list.group(of: list.ordered[index - 1].id) {
                            Theme.line.frame(width: 24, height: 1).padding(.vertical, 4)
                        }
                        VStack(spacing: 4) {
                            Text("\(list.lineNumber(of: index, cursor: model.cursor))")
                                .font(Theme.mono(10, weight: isCursor ? .bold : .regular))
                                .foregroundStyle(isCursor ? Theme.fg : Theme.fg3)
                            StateGlyph(state: agent?.state ?? .exited, guessed: agent?.source == .guessed)
                            if let pin = list.pins.firstIndex(of: task) {
                                Text("'\(pin + 1)").font(Theme.mono(9)).foregroundStyle(Theme.fg3)
                            }
                        }
                        .frame(width: 44)
                        .padding(.vertical, 8)
                        .background(isCursor ? Theme.bg3 : .clear)
                        .overlay(alignment: .topLeading) {
                            if let hint = model.hintLabel(for: .task(task.id)) { HintBadge(label: hint) }
                        }
                        .help(task.title)
                        .contentShape(Rectangle())
                        .onTapGesture { model.clickTask(task.id) }
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            model.clickTask(task.id, insert: true)
                        })
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 48)
        .background(Theme.bg2)
        .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
    }
}

/// A small chevron button that collapses or expands a pane, with its key in the tooltip.
struct CollapseButton: View {
    let systemImage: String
    let key: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(Theme.fg3)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("collapse / expand (\(key))")
    }
}
