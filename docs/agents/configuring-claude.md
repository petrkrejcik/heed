---
description: Changing the command line Heed starts claude with.
---

# Configuring claude

`[agents.claude]` changes how Heed starts claude, field by field. Fields you leave out keep their defaults.

```toml
[agents.claude]
command = "claude"
resume = "--resume {id}"
```

| Field | |
|---|---|
| `command` | The command line that starts claude, e.g. `claude --model opus`. |
| `prompt` | How the prompt reaches it: `argument` (appended), `stdin` (piped in), `paste` or `file`. |
| `resume` | Arguments that resume an agent tab; `{id}` is its Claude session id. Without it, a resumed agent starts fresh. |
| `[agents.claude.profiles]` | Named command lines, `name = "command"`. |

Settings (`⌘,`) edits the same fields. Other agents run in a plain terminal tab, without a state; Heed ignores
`[agents.<name>]` tables for them.
