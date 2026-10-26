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
                                ForEach(section.tasks) { task in
                                    let index = list.ordered.firstIndex(of: task) ?? 0
                                    TaskRow(
                                        task: task,
                                        rollup: list.rollup(of: task.id),
                                        number: list.lineNumber(of: index, cursor: model.cursor),
                                        isCursor: index == model.cursor,
                                        pinNumber: list.pins.firstIndex(of: task).map { $0 + 1 },
                                        hint: model.hintLabel(for: .task(task.id)),
                                        pull: model.pullStatus(of: task)
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

            if list.ordered.isEmpty {
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

    /// Needs you in amber; the rest quiet.
    static func tint(_ group: TaskGroup) -> Color {
        group == .needsYou ? Theme.block : Theme.fg3
    }

    private func groupHeader(_ section: TaskList.Section, pins: Int) -> some View {
        HStack(spacing: 6) {
            if section.group == .pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.fg3)
            }
            let count = section.group == .pinned ? "\(pins)/\(TaskGroup.maxPins)" : "\(section.tasks.count)"
            SectionHeader(
                title: "\(section.group.rawValue) · \(count)",
                tint: Self.tint(section.group)
            )
            Spacer()
            if section.group == .pinned { KeyCap(text: "'") }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

/// One task: its title and worktree folder, the most urgent agent's glyph, Kibana when it runs, and its PR.
struct TaskRow: View {
    let task: WorkTask
    let rollup: TaskRollup
    let number: Int
    let isCursor: Bool
    let pinNumber: Int?
    let hint: String?
    var pull: PullStatus?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(Theme.mono(11, weight: isCursor ? .bold : .regular))
                .foregroundStyle(isCursor ? Theme.fg : Theme.fg3)
                .frame(width: 22, alignment: .trailing)
                .padding(.top, 1)
            Group {
                if let agent = rollup.agent {
                    StateGlyph(state: agent.state, guessed: agent.source == .guessed)
                } else {
                    StateGlyph(state: .exited)
                }
            }
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(Theme.ui(13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(task.title)
                    Spacer(minLength: 4)
                    if let pinNumber { KeyCap(text: "'\(pinNumber)") }
                    if rollup.kibanaRunning, let port = task.port { KibanaMark(port: port) }
                    if let ref = task.pull {
                        HStack(spacing: 4) {
                            if let pull { PullMark(status: pull, compact: true) }
                            Text(verbatim: "#\(ref.number)").font(Theme.mono(10.5)).foregroundStyle(Theme.fg2)
                        }
                    }
                }
                Text(task.worktreeName ?? "main checkout")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.fg3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !activity.isEmpty {
                    Text(activity)
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.fg3)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .background(isCursor ? Theme.bg3 : .clear)
        .overlay(alignment: .topLeading) {
            if let hint { HintBadge(label: hint).padding(.leading, 8).padding(.top, 8) }
        }
    }

    /// "2 agents · running jest · 2m"; a single agent just says what it does.
    private var activity: String {
        let count = rollup.agentCount > 1 ? "\(rollup.agentCount) agents" : nil
        return [count, rollup.activity.isEmpty ? nil : rollup.activity].compactMap(\.self).joined(separator: " · ")
    }
}

/// Kibana running for a task: a K and its port.
struct KibanaMark: View {
    let port: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "k.square.fill").font(.system(size: 10))
            Text(verbatim: "\(port)").font(Theme.mono(10.5))
        }
        .foregroundStyle(Theme.done)
        .help("Kibana running on localhost:\(port)")
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

/// The collapsed sidebar: one row per task with its number, agent glyph and pin, so moving and jumping still work.
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
