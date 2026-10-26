---
description: Running any command by name from the command line.
---

# The command line

`:` opens the command line. Every command has a name, and `:` runs any of them, with completion.

![The command line, completing view](../images/shots/keyboard/command-line.png)

| Key | |
|---|---|
| `⇥` | Complete |
| `↩` | Run |
| `⎋` | Close |
| `⌘V` | Paste (on one line) |

Short forms work too:

| Typed | Runs |
|---|---|
| `:new <title>` | New task with that title |
| `:review 2841` | Review pull request 2841 (its URL works too) |
| `:task <words>`, `:status <name>`, `:pin` | Go to a task, set its status, pin it |
| `:pr 2841` | Read pull request 2841 |
| `:tasks`, `:inbox`, `:prs`, … | Switch view |
| `:help` | Every key |
| `:q` | Quit |

## Commands without a key

Everything you can do with the mouse, the menu bar or a global shortcut is a command too, so `:` reaches it and
`config.toml` can bind it:

| Command | |
|---|---|
| `:task.open <words>` | Go to the first task matching the words |
| `:tab.go <n>` | Go to tab n |
| `:filter.clear` | Clear the view's filter |
| `:issues.repo [name]` | Show one repo's issues; no name shows every repo |
| `:resume` | The "pick up where you left off" dialog, as on launch |
| `:settings.open [section]` | Settings, on `general`, `agents` or `keys` |
| `:app.activate` | Bring the window to the front |

The [key reference](reference.md) lists every command name.
