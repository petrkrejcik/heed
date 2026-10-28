/// Short forms accepted on the `:` line, mapped onto canonical command names: `:new <title>`, `:pr 2841`. Anything
/// else is taken as a command name as typed.
public enum CommandAliases {
    public static func resolve(_ line: String) -> CommandInvocation {
        let typed = CommandInvocation(parsing: line)
        let args = typed.arguments
        switch typed.name {
        case "new": return CommandInvocation(name: "task.new", arguments: args)
        case "task": return CommandInvocation(name: "task.open", arguments: args)
        case "status": return CommandInvocation(name: "task.status", arguments: args)
        case "pin": return CommandInvocation(name: "task.pin", arguments: args)
        case "section": return CommandInvocation(name: "section.toggle", arguments: args)
        case "review": return CommandInvocation(name: "task.review", arguments: args)
        case "worktree": return CommandInvocation(name: "task.worktree", arguments: args)
        case "pr": return CommandInvocation(name: "open.reader", arguments: ["pr"] + args)
        case "help": return CommandInvocation(name: "overlay.help")
        case "diff": return CommandInvocation(name: "tab.diff")
        case "q", "quit": return CommandInvocation(name: "app.quit")
        default:
            if let view = ["tasks", "inbox", "issues", "prs"].first(where: { $0 == typed.name }) {
                return CommandInvocation(name: "view", arguments: [view])
            }
            return typed
        }
    }
}
