/// One line of a right-click menu: a command, with a short label. The menu shows the command's key beside it.
public struct MenuItem: Equatable, Sendable {
    public let title: String
    public let command: CommandInvocation
    public var enabled: Bool
    /// A check mark: the item is what the thing already is (the task's status).
    public var checked: Bool

    public init(_ title: String, _ command: CommandInvocation, enabled: Bool = true, checked: Bool = false) {
        self.title = title
        self.command = command
        self.enabled = enabled
        self.checked = checked
    }

    /// What to type for it when no key is bound: `:status todo`.
    public var typed: String {
        let name = command.name == "task.status" ? "status" : command.name
        return ":" + ([name] + command.arguments).joined(separator: " ")
    }

    /// The keys among `bindings` that run this item's command. A status matches by what it names, so a binding to
    /// `task.status wip` is In Progress's key as much as `task.status in-progress` is.
    public func keys(in bindings: [(keys: [KeyStroke], command: String)]) -> [[KeyStroke]] {
        bindings.filter { Self.same(CommandInvocation(parsing: $0.command), command) }.map(\.keys)
    }

    private static func same(_ bound: CommandInvocation, _ command: CommandInvocation) -> Bool {
        guard bound.name == command.name else { return false }
        guard command.name == "task.status" else { return bound.arguments == command.arguments }
        let status = TaskStatus.named(command.arguments.joined(separator: " "))
        return status != nil && TaskStatus.named(bound.arguments.joined(separator: " ")) == status
    }
}

public enum MenuEntry: Equatable, Sendable {
    /// The thing the menu is about, greyed at the top.
    case header(String)
    case item(MenuItem)
    /// A titled list of entries that opens beside the menu ("Status").
    case submenu(String, [MenuEntry])
    case separator
}

/// The right-click menus, from plain facts about what was clicked. Every item runs a command that has a key or a `:`
/// name, so a menu never does anything the keyboard cannot.
public enum ContextMenus {
    /// The statuses in the order of the sidebar's sections and the Kanban's columns; the two that end a task last.
    public static let statusOrder: [TaskStatus] = [.toDo, .inProgress, .blocked, .readyForReview, .done, .dropped]

    /// A task in the sidebar or the rail: its title, its PR page when it has a PR, then Status. The menu selects the
    /// task first, so `overlay.item` is the task's PR page, and shows its key (`go`).
    public static func task(_ task: WorkTask) -> [MenuEntry] {
        let pull: [MenuEntry] = task.pull == nil ? [] : [.item(MenuItem("Pull request", CommandInvocation(
            name: "overlay.item"
        )))]
        return [.header(task.title)] + pull + [.submenu("Status", statuses(current: task.status))]
    }

    /// Every status pk knows, the task's own checked. Done and Dropped ask first, hence the ellipsis.
    static func statuses(current: TaskStatus) -> [MenuEntry] {
        statusOrder.flatMap { status -> [MenuEntry] in
            let item = MenuItem(
                status.endsTask ? "\(status)…" : status.rawValue,
                CommandInvocation(name: "task.status", arguments: [shortName(status)]),
                checked: status == current
            )
            return status == .done ? [.separator, .item(item)] : [.item(item)]
        }
    }

    /// The name `:status` takes for it, as the default keys use them.
    static func shortName(_ status: TaskStatus) -> String {
        switch status {
        case .toDo: "todo"
        case .inProgress: "in-progress"
        case .readyForReview: "review"
        default: status.rawValue.lowercased()
        }
    }
}
