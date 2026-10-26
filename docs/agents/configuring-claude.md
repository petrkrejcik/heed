---
description: Changing the command line Heed starts claude with.
---

# Configuring claude

`[agents.claude]` changes how Heed starts claude, field by field. Fields you leave out keep their defaults.

```toml
[agents.claude]
command = "claude"
plan = "--permission-mode plan"
resume = "--resume {id}"
```

| Field | |
|---|---|
| `command` | The command line that starts claude, e.g. `claude --model opus`. |
| `prompt` | How the prompt reaches it: `argument` (appended), `stdin` (piped in), `paste` or `file`. |
| `plan` | Arguments for **Plan first** in Start work. |
| `resume` | Arguments that resume a session; `{id}` is claude's session id. Without it, a resumed session starts fresh. |
| `[agents.claude.profiles]` | Named command lines, `name = "command"`. |

Settings (`⌘,`) edits the same fields. Other agents run in a plain terminal tab, without a state; Heed ignores
`[agents.<name>]` tables for them.
